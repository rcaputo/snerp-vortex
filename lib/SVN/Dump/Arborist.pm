package SVN::Dump::Arborist;

# Build and manage repository trees.
# Find branches and tags based on svn copy operations.

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Dump::Entity;
use SVN::Dump::Snapshot;
use SVN::Dump::Revision;
use SVN::Dump::Copy;

use constant DEBUG => 0;
use YAML::Syck; # for debugging

use Carp qw(croak);
use Storable qw(dclone);

# Map entity paths to the entities themselves.  Entities are
# versioned because a path may refer to more than one over time.  Even
# so, a path may only refer to a single entity at any revision.
has path_to_entities => (
	is => 'rw',
	isa => 'HashRef[ArrayRef[SVN::Dump::Entity]]',
	default => sub { {} },
);

has snapshots => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Snapshot]',
	default => sub { [] },
);

has copy_sources => (
	is      => 'rw',
	isa     => 'HashRef[HashRef[SVN::Dump::Copy]]',
	default => sub { {} },
);

has pending_revision => (
	is      => 'rw',
	isa     => 'SVN::Dump::Revision',
	clearer => 'clear_pending_revision',
);

#######################################
### 1st walk: Analyze branch lifespans.

# New nodes may be entities.
sub on_node_add {
	my ($self, $revision, $path, $kind, $data) = @_;

	DEBUG and print "adding $kind $path at $revision\n";

	$self->analyze_new_node($revision, $path, $kind);
}

# Copy destinations may be entities.
sub on_node_copy {
	my ($self, $dst_rev, $dst_path, $kind, $src_rev, $src_path, $text) = @_;

	DEBUG and print(
		"copying $kind $src_path at $src_rev -> $dst_path at $dst_rev\n"
	);

	# Identify file and directory copies, and track whether they create
	# branches or tags.
	$self->analyze_new_node($dst_rev, $dst_path, $kind);

	$self->copy_sources()->{$src_rev}{$src_path} = SVN::Dump::Copy->new(
		src_revision  => $src_rev,
		src_path      => $src_path,
	);
}

# Entities may be deleted.
sub on_node_delete {
	my ($self, $revision, $path) = @_;

	$self->touch_entity($revision, $path);
	my $entity = $self->get_entity($path);
	$entity->exists(0) if $entity;

	undef;
}

# Alterations touch entities.
sub on_node_change {
	my ($self, $revision, $path, $kind, $data) = @_;
	$self->touch_entity($revision, $path);
	undef;
}

# At the end of the walk, fix the types of all found entities.
sub on_walk_done {
	my $self = shift;
	$_->fix_type() foreach map { @$_ } values %{$self->path_to_entities()};
}

# Determine and remember a path's entity hint.  If the path doesn't
# describe an entity, then touch the entity that contains it.  This
# latter behavior may be overloading it a bit.

sub analyze_new_node {
	my ($self, $revision, $path, $kind) = @_;

	my ($entity_type, $entity_name) = $self->calculate_entity($kind, $path);

	if ($entity_type =~ /^(?:file|dir)$/) {
		$self->touch_entity($revision, $path);
		return;
	}

	DEBUG and print "  creates $entity_type $entity_name\n";

	# Stored in reverse so foreach begins at the end.
	unshift(
		@{$self->path_to_entities()->{$path}},
		SVN::Dump::Entity->new(
			first_revision_id => $revision,
			last_revision_id  => $revision,
			type              => $entity_type,
			name              => $entity_name,
			exists            => 1,
			path              => $path,
		),
	);

	return 1;
}

####################################################
### 2nd walk: Track current state of the repository.

sub start_revision {
	my ($self, $revision, $author, $time, $log_message) = @_;

	# Revision doesn't match expectation?
	my $snapshots = $self->snapshots();
	my $next_revision = @$snapshots;
	croak "expecting revision $next_revision" unless $revision == $next_revision;

	# Record a new snapshot.
	push @$snapshots, SVN::Dump::Snapshot->new(
		revision  => $revision,
		author    => $author,
		time      => $time,
		message   => $log_message,
		root      => SVN::Dump::Snapshot::Dir->new( revision => $revision ),
	);

	$self->pending_revision(
		SVN::Dump::Revision->new(
			id      => $revision,
			author  => $author,
			time    => $time,
			message => $log_message,
		)
	);

	# Revision zero?  No prior revision to worry about.
	return unless $revision;

	# Clean up obsolete prior revisions.
	my $copy_sources = $self->copy_sources();

	# Remove obsolete referenced revisions.
	foreach my $src (sort { $a <=> $b } keys %$copy_sources) {

		# Copy source is too recent.  We're done.
		last if $src > $revision - 2;

		# Copy source is used by this or a later rev.  We need it.
		next if $copy_sources->{$src} >= $revision;

		# The copy source is now obsolete.
		delete $copy_sources->{$src};
		$snapshots->[$src] = undef;

		# TODO - Delete the copy source from the filesystem?
	}

	# Previous revision isn't a copy source.
	# Bump its data up to this revision.
	unless (exists $copy_sources->{$revision-1}) {
		$snapshots->[$revision] = $snapshots->[$revision-1];
		$snapshots->[$revision-1] = undef;

		$snapshots->[$revision]->revision($revision);
		$snapshots->[$revision]->author($author);
		$snapshots->[$revision]->time($time);
		$snapshots->[$revision]->message($log_message);
		return;
	}

	# Previous revision has a copy destination.
	# Clone it to this one.
	$snapshots->[$revision] = dclone($snapshots->[$revision-1]);
	$snapshots->[$revision]->revision($revision);
	$snapshots->[$revision]->author($author);
	$snapshots->[$revision]->time($time);
	$snapshots->[$revision]->message($log_message);
	return;
}

sub finalize_revision {
	my $self = shift;

	my $new_revision = $self->pending_revision();
	$self->clear_pending_revision();
	$new_revision->optimize();

	return $new_revision;
}

sub add_new_node {
	my ($self, $revision, $path, $kind, $content) = @_;

	my $entity = $self->get_historical_entity($revision, $path);
	die "$path at $revision has no entity" unless defined $entity;

	my ($node, $change);
	if ($kind eq "dir") {
		$node = SVN::Dump::Snapshot::Dir->new(revision => $revision);
		$change = SVN::Dump::Change::Mkdir->new(
			path      => $path,
			container => $entity,
		);
	}
	elsif ($kind eq "file") {
		$node = SVN::Dump::Snapshot::File->new(
			revision  => $revision,
		);
		$change = SVN::Dump::Change::Mkfile->new(
			path      => $path,
			content   => $content,
			container => $entity,
		);
	}
	else {
		die "strange kind: $kind";
	}

	$self->add_node($revision, $path, $node);
	$self->pending_revision()->push_change($change);
}

sub add_node {
	my ($self, $revision, $path, $new_node) = @_;

	# Sanity check?
	die YAML::Syck::Dump($self->snapshots()) unless (
		$revision == $self->snapshots()->[-1]->revision()
	);
	confess("new revision $revision != ", $self->snapshots()->[-1]->revision())
	unless $revision == $self->snapshots()->[-1]->revision();

	my $node = $self->snapshots()->[-1]->root();

	my @path = split /\//, $path;
	while (@path > 1) {
		my $next = shift @path;
		$node = $node->contents()->{$next};
	}

	return $node->contents()->{$path[0]} = $new_node;
}

sub find_node {
	my ($self, $path, $rev) = @_;

	my $node = $self->snapshots()->[$rev || -1]->root();

	my @path = split /\//, $path;
	foreach (@path) {
		return unless exists $node->contents()->{$_};
		$node = $node->contents()->{$_};
	}

	return $node;
}

sub touch_node {
	my ($self, $path, $kind, $content) = @_;

	my $node = $self->find_node($path);
	confess "node is not defined at $path" unless defined $node;
	my $revision = $self->snapshots()->[-1]->revision();
	$node->revision($revision);

	# Some changes don't alter content.  We'll skip them, since most
	# Subversion properties aren't portable.
	if (defined $content) {
		$self->pending_revision()->push_change(
			SVN::Dump::Change::Edit->new(
				path      => $path,
				content   => $content,
				container => $self->get_historical_entity($revision, $path),
			)
		);
	}
}

###################
### Helper methods.

# Determine an entity type and name hint from a path and kind.
sub calculate_entity {
	my ($self, $kind, $path) = @_;

	return("file", $path) if $kind eq "file";
	die $kind if $kind ne "dir";

	if ($path =~ /^tags\/([^\/]+)$/) {
		(my $tag = $1) =~ s/[-\/_\s]+/_/g;
		return("tag", $tag);
	}

	if ($path =~ /^branches\/([^\/]+)$/) {
		(my $branch = $1) =~ s/[-\/_\s]+/_/g;
		return("branch", $branch);
	}

	if ($path eq "trunk") {
		#if ($path =~ /^trunk\/(\S+)$/) 
		return("branch", "trunk");
	}

	return("meta", $path) if $path =~ /^(?:trunk|tags|branches)$/;

	return("dir", $path);
}

# Register that an entity has been modified at a particular revision.
# We assume that modifications occur in monotonically increasing time,
# so we only touch the last entity registered at the path.  If this
# assumption is false SVN::Dump::Entity will need a touch() method.

sub touch_entity {
	my ($self, $revision, $path) = @_;

	foreach my $entity ($self->get_path_containers($path)) {
		die unless $entity->exists();
		$entity->last_revision_id($revision);
	}

	return;
}

# Find the entities that contains a path.  Returns them in most to
# least specific order.
sub get_path_containers {
	my ($self, $path) = @_;

	my @entities;

	my @path = split /\/+/, $path;
	while (@path) {
		my $test_path = join("/", @path);
		next unless exists $self->path_to_entities()->{$test_path};
		croak "oooo" unless $self->path_to_entities()->{$test_path}->[-1]->exists();
		push @entities, $self->path_to_entities()->{$test_path}->[-1];
	}
	continue {
		pop @path;
	}

	return @entities;
}

# Return the current entity at a path, or undef if none is there.
sub get_entity {
	my ($self, $path, $revision) = @_;

	$revision = -1 unless defined $revision;

	return unless exists $self->path_to_entities()->{$path};

	foreach my $candidate_entity (@{$self->path_to_entities()->{$path}}) {
		next if $revision > $candidate_entity->last_revision_id();
		next if $revision < $candidate_entity->first_revision_id();
		return $candidate_entity;
	}

	# No match. :(
	return;
}

sub get_historical_entity {
	my ($self, $revision, $path) = @_;

#	my $exact_entity = $self->get_entity($path, $revision);
#	return $exact_entity if $exact_entity;

	my @path = split /\/+/, $path;
	while (@path) {
		my $test_path = join("/", @path);
		next unless exists $self->path_to_entities()->{$test_path};

		ENTITY: foreach my $entity (@{$self->path_to_entities()->{$test_path}}) {
			next ENTITY if $revision > $entity->last_revision_id();
			next ENTITY if $revision < $entity->first_revision_id();
			return $entity;
		}
	}
	continue {
		pop @path;
	}

	return;
}

sub delete_node {
	my ($self, $path) = @_;

	my $node = $self->snapshots()->[-1]->root();

	my @path = split /\//, $path;
	while (@path > 1) {
		my $segment = shift @path;
		$node = $node->contents()->{$segment};
	}

	my $deleted_node = delete $node->contents()->{$path[0]};

	my $deletion_class;
	if ($deleted_node->isa("SVN::Dump::Snapshot::Dir")) {
		$deletion_class = "SVN::Dump::Change::Rmdir";
	}
	elsif ($deleted_node->isa("SVN::Dump::Snapshot::File")) {
		$deletion_class = "SVN::Dump::Change::Rmfile";
	}
	else {
		die "unexpected node class: $deleted_node";
	}

	# TODO - Validate node kind?
	$self->pending_revision()->push_change(
		$deletion_class->new(
			path      => $path,
			container => $self->get_historical_entity($node->revision(), $path),
		)
	);

	return $deleted_node;
}

sub copy_node {
	my ($self, $src_rev, $src_path, $revision, $dst_path, $kind, $data) = @_;

	my $src_node = $self->find_node($src_path, $src_rev);
	die "copy from $src_path to $dst_path unknown" unless $src_node;
	die(
		"copy source $src_path kind is wrong: ", $src_node->kind(),
		" but expected $kind", "\n", YAML::Syck::Dump($self->snapshots())
	) unless $src_node->kind() eq $kind;

	my $dst_node = $self->find_node($dst_path);
	die "copy dest path already exists" if $dst_node;

	my $cloned_branch = dclone($src_node);
	my @nodes = ($cloned_branch);
	while (@nodes) {
		my $node = shift @nodes;
		push @nodes, values %{$node->contents()} if $node->can("content");
		$node->revision($revision);
	}

	$self->add_node($revision, $dst_path, $cloned_branch);

	my $change_class = "SVN::Dump::Change::Cp$kind";
	$self->pending_revision()->push_change(
		$change_class->new(
			path          => $dst_path,
			container     => $self->get_historical_entity($revision, $dst_path),
			src_rev       => $src_rev,
			src_path      => $src_path,
			src_container => $self->get_historical_entity($src_rev, $src_path),
			content       => $data,
		)
	);
}

#sub DEMOLISH {
#	my $self = shift;
#	use YAML::Syck; print YAML::Syck::Dump($self->path_to_entities());
#	exit;
#}

1;
