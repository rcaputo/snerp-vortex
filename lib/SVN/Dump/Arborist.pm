package SVN::Dump::Arborist;

# Build and manage repository trees.
# Find branches and tags based on svn copy operations.

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Dump::Entity;
use SVN::Dump::Snapshot;
use SVN::Dump::Revision;
use SVN::Dump::Copy;

use YAML::Syck; # for debugging

use Carp qw(croak);
use Storable qw(dclone);

# Map entity paths to the entities themselves.  Entities are
# versioned because a path may refer to more than one over time.  Even
# so, a path may only refer to a single entity at any revision.
has path_to_entities => (
	is => 'rw',
	isa => 'HashRef[ArrayRef[SVN::Dump::Entity]]',
	default => sub {
		{
			"" => [
				SVN::Dump::Entity->new(
					first_revision_id => 0,
					type              => "meta",
					name              => "root",
					exists            => 1,
					path              => "",
					modified          => 0,
				),
			],
		},
	},
);

has snapshots => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Snapshot]',
	default => sub { [] },
);

has copy_sources => (
	is      => 'rw',
	isa     => 'HashRef[HashRef[ArrayRef[SVN::Dump::Copy]]]',
	default => sub { {} },
);

has pending_revision => (
	is      => 'rw',
	isa     => 'SVN::Dump::Revision',
	clearer => 'clear_pending_revision',
);

has entities_to_fix => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Entity]',
	default => sub { [] },
);

has verbose => ( is => 'ro', isa => 'Bool', default => 0 );

#######################################
### 1st walk: Analyze branch lifespans.

# Analyze new nodes at the times they are added.  Determine whether
# they're entities, and keep track of them if they are
sub on_node_add {
	my ($self, $revision, $path, $kind, $data) = @_;
	$self->log("adding $kind $path at $revision");
	$self->analyze_new_node($revision, $path, $kind);
}

# Copy destinations may be entities.  Analyze them as they are created
# by copies.
sub on_node_copy {
	my ($self, $dst_rev, $dst_path, $kind, $src_rev, $src_path, $text) = @_;

	$self->log("copying $kind $src_path at $src_rev -> $dst_path at $dst_rev");

	# Identify file and directory copies, and track whether they create
	# branches or tags.
	my $new_entity = $self->analyze_new_node($dst_rev, $dst_path, $kind);

	# If source and destination are entities, then record the copy for
	# later analysis.
	my $src_entity = $self->get_entity($src_path, $src_rev);
	my $dst_entity = $self->get_entity($dst_path, $dst_rev);

	if ($src_entity and $src_entity->type() =~ /^(?:branch|tag)$/) {
		# Source is an entity.
		if ($dst_entity and $dst_entity->type() =~ /^(?:branch|tag)$/) {
			# Source and destination are entities.

			# Sanity check that the destination is the entity just created.
			unless ($dst_entity == $new_entity) {
				die(
					$src_entity->debug("src(%s) "),
					$dst_entity->debug("dst(%s) "),
					$new_entity->debug("new(%s)\n"),
				);
			}

			$self->log("  entity to entity copy");
			push @{$src_entity->descendents()}, $dst_entity;
		}
		else {
			# Destination is not an entity.
		}
	}
	elsif ($dst_entity and $dst_entity->type() =~ /^(?:branch|tag)$/) {
		# Non-entity to entity.
		# Subversion supports branching and tagging subdirectories as well
		# as entire projects.
	}
	else {
		# Non-entity to non-entity.
	}

	# Recall the copy source, in case we need to take a source snapshot
	# during replay.
	push(
		@{$self->copy_sources()->{$src_rev}{$src_path}},
		SVN::Dump::Copy->new(
			src_revision  => $src_rev,
			src_path      => $src_path,
			dst_revision  => $dst_rev,
			dst_path      => $dst_path,
		)
	);
}

# Entities may be deleted.
sub on_node_delete {
	my ($self, $revision, $path) = @_;

	# Deleting an entity touches its containers and itself.  Its
	# containers are modified, but itself isn't.
	foreach my $entity ($self->get_path_containers($path)) {
		die unless $entity->exists();
		next if $entity->path() eq $path;
		$entity->modified(1);
	}

	# The deleted entity doesn't exist.
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
	$_->fix_type() foreach @{$self->entities_to_fix()};

	# Different VCSs may need to perform specific activities at this
	# time.  They can achieve the same timing by adding specific logic
	# to their "before" or "after" on_walk_begin methods.
}

# Determine and remember a path's entity hint.  If the path doesn't
# describe an entity, then touch the entity that contains it.  This
# latter behavior may be overloading it a bit.

sub analyze_new_node {
	my ($self, $revision, $path, $kind) = @_;

	my ($entity_type, $entity_name) = $self->calculate_entity($kind, $path);

	# Adding a plain file or directory to an entity touches that entity,
	# and all the entities it contains.
	if ($entity_type =~ /^(?:file|dir)$/) {
		$self->touch_entity($revision, $path);
		return;
	}

	$self->log("  creates $entity_type $entity_name at $revision");

	# Copy creates a new entity.
	my $new_entity = SVN::Dump::Entity->new(
		first_revision_id => $revision,
		type              => $entity_type,
		name              => $entity_name,
		exists            => 1,
		path              => $path,
		modified          => 0,
	);

	push @{$self->path_to_entities()->{$path}}, $new_entity;
	push @{$self->entities_to_fix()}, $new_entity;

	# In case it needs to be manipulated further.
	return $new_entity;
}

##########################################################
### Track current state of the repository during Replayer.

sub start_revision {
	my ($self, $revision, $author, $time, $log_message) = @_;

	# Revision doesn't match expectation?
	my $snapshots = $self->snapshots();
	my $next_revision = @$snapshots;
	croak "expecting revision $next_revision" unless $revision == $next_revision;

	croak "opening an unfinalized revision" if (
		$self->pending_revision() and $self->pending_revision()->is_open()
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
	unless ($revision) {
		# Record a new snapshot.
		push @$snapshots, SVN::Dump::Snapshot->new(
			revision  => $revision,
			author    => $author,
			time      => $time,
			message   => $log_message,
			root      => SVN::Dump::Snapshot::Dir->new( revision => $revision ),
		);

		$self->log("SNP) added snapshot at $next_revision");
		return;
	}

	# Clean up obsolete prior revisions.
	my $copy_sources = $self->copy_sources();

	# Remove obsolete referenced revisions.
	foreach my $src (sort { $a <=> $b } keys %$copy_sources) {

		# No need to continue beyond recent history.
		last if $src > $revision - 2;

		# Discard any copy destinations that are before now.
		while (my ($src_path, $copies) = each %{$copy_sources->{$src}}) {

			my $i = @$copies;
			while ($i--) {
				# Copy goes to a present or future revision.  Keep it.
				next if $copies->[$i]->dst_revision() >= $revision;

				# Copy goes to a previous revision.  We can remove it.
				splice @$copies, $i, 1;
			}

			# If we've removed all copies for the source revision and path,
			# then remove the source path.
			unless (@$copies) {
				$self->log("CPY) copy sources for $src $src_path are all gone");
				delete $copy_sources->{$src}->{$src_path};
			}
		}

		# All copies are gone for the source revision?  We can get rid of
		# that, too.
		unless (scalar keys %{$copy_sources->{$src}}) {
			delete $copy_sources->{$src};
			$self->log("SNP) clearing snapshot at revision $src");

			# And the snapshot at that revision is also obsolete.
			$snapshots->[$src] = undef;

			# TODO - Remove the copy source from the depot.  However, this
			# is a Replayer thing, not an Arborist one.  The division of
			# responsibility needs to be clarified here.
		}
	}

	# Previous revision isn't a copy source.
	# Bump its data up to this revision.
	unless (exists $copy_sources->{$revision-1}) {
		$self->log("SNP) bumping snapshot from previous revision to $revision");

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
	$self->log("REV) cloning previous revision to $revision");
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
	$new_revision->is_open(0);
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

	$rev = -1 unless defined $rev;
croak "no node for snapshot revision $rev" unless (
	$self->snapshots()->[$rev]
);
	my $node = $self->snapshots()->[$rev]->root();

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

	if ($kind eq "file") {
		return("file", $self->calculate_relative_path($path));
	}

	die $kind if $kind ne "dir";

	if ($path =~ /(^.*?)\/?tags\/([^\/]+)$/) {
		my ($project, $tag) = ($1, $2);
		$project =~ s/[-\/_\s]+/_/g;
		$tag =~ s/[-\/_\s]+/_/g;
		if (defined $project and length $project) {
			return("tag", "$project-$tag");
		}
		return("tag", $tag);
	}

	if ($path =~ /(^.*?)\/?branch(?:es)?\/([^\/]+)$/) {
		my ($project, $branch) = ($1, $2);
		$project =~ s/[-\/_\s]+/_/g;
		$branch =~ s/[-\/_\s]+/_/g;
		if (defined $project and length $project) {
			return("branch", "$project-$branch");
		}
		return("branch", $branch);
	}

	if ($path =~ /(^.*?)\/?trunk(?:\/|$)/) {
		(my $project = $1) =~ s/[-\/_\s]+/_/g;
		if (defined $project and length $project) {
			return("branch", "$project-trunk");
		}
		return("branch", "trunk");
	}

	#return("meta", $path) if $path =~ /^(?:trunk|tags|branches)$/;
	return("branch", "trunk") if $path =~ /^(?:trunk|tags|branches)$/;

	return("dir", $self->calculate_relative_path($path));
}

# NOTE - The prefixes that are extracted should be defined in terms of
# the ones in calculate_entity().
sub calculate_relative_path {
	my ($self, $path) = @_;

	$path =~ s/^.*?\/?tags\/[^\/]+\/?// or
	$path =~ s/^.*?\/?branch(?:es)?\/[^\/]+\/?// or
	$path =~ s/^.*?\/?trunk\/?// or
	$path =~ s/^(?:trunk|tags|branches)$//
	;

	return $path;
}

sub touch_entity {
	my ($self, $revision, $path) = @_;

	foreach my $entity ($self->get_path_containers($path)) {
		die unless $entity->exists();
		$entity->modified(1);
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

	foreach my $candidate (reverse @{$self->path_to_entities()->{$path}}) {
		next if $revision < $candidate->first_revision_id();
		return $candidate;
	}

	# No match. :(
	return;
}

# Find the most specific containing entity.
sub get_historical_entity {
	my ($self, $revision, $path) = @_;

	my @path = ("", (split /\/+/, $path));
	while (@path) {
		# Skip the leading "" to avoid causing a leading "/".
		# TODO - Feels a little hacky, in a bad way.
		my $test_path = join("/", @path[1..$#path]);

		next unless exists $self->path_to_entities()->{$test_path};

		foreach my $entity (reverse @{$self->path_to_entities()->{$test_path}}) {
			next if $revision < $entity->first_revision_id();
			return $entity;
		}
	}
	continue {
		pop @path;
	}

	# TODO - Should code ever reach this now that we have meta root?
	return;
}

sub delete_node {
	my ($self, $path, $revision) = @_;

	# Find the root node.
	my $node = $self->snapshots()->[$revision]->root();

	# Walk the contents for each path segment except the last.
	my @path = split /\//, $path;
	while (@path > 1) {
		my $segment = shift @path;
		$node = $node->contents()->{$segment};
	}

	# Delete the last segment from its container.
	my $deleted_node = delete $node->contents()->{$path[0]};

	# Map the deleted node class to a change class.
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

	# Instantiate the change, and add it to the revision.
	$self->pending_revision()->push_change(
		$deletion_class->new(
			path      => $path,
			container => $self->get_historical_entity($revision, $path),
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

sub log {
	my $self = shift;
	return unless $self->verbose();
	print time() - $^T, " ", join("", @_), "\n";
}

1;
