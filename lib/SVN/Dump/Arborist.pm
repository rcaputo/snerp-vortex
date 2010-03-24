package SVN::Dump::Arborist;

# TODO - Maybe rename to Replay?

# Build and manage repository trees.
# Find branches and tags based on svn copy operations.

use Moose;

use SVN::Dump::Entity;
use SVN::Dump::Snapshot;
use SVN::Dump::Revision;
use SVN::Dump::Copy;
use SVN::Analysis;
use SVN::Dump::Analyzer;

use YAML::Syck; # for debugging

use Carp qw(croak);
use Storable qw(dclone);

has analysis_filename => ( is => 'rw', isa => 'Maybe[Str]' );

has analysis => (
	is      => 'rw',
	isa     => 'SVN::Analysis',
	lazy    => 1,
	default => sub {
		my $self = shift;

		my $analysis = SVN::Analysis->new( verbose => $self->verbose() );

		# Load a prepared file.
		if (defined $self->analysis_filename()) {
			$analysis->init_from_xml_file($self->analysis_filename());
			$analysis->analyze();
			return $analysis;
		}

		# Otherwize analyze the svn dump in place.
		my $analyzer = SVN::Dump::Analyzer->new(
			svn_dump_filename => $self->svn_dump_filename(),
			verbose           => $self->verbose(),
		);
		$analyzer->walk();
		return $analyzer->analysis();
	},
);

has verbose => ( is => 'ro', isa => 'Bool', default => 0 );
has svn_dump_filename => ( is => 'ro', isa => 'Str' );

has pending_revision => (
	is      => 'rw',
	isa     => 'SVN::Dump::Revision',
	clearer => 'clear_pending_revision',
);

##############################################################################
### Replay revisions.  Accumulate changes, then flush when revisions are done.

# Create a new SVN::Dump::Revision, and prepare it to buffer changes.

sub start_revision {
	my ($self, $revision, $author, $time, $log_message) = @_;

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

	return;
}

# A revision has finished.
# Close it, and return it for a subclass to perform.

sub finalize_revision {
	my $self = shift;

	my $new_revision = $self->pending_revision();
	$new_revision->is_open(0);
	$new_revision->optimize();

	return $new_revision;
}

# A change has added a new node to this revision.

sub add_new_node {
	my ($self, $revision, $path, $kind, $content) = @_;

	my ($node, $change);
	if ($kind eq "dir") {
		$node = SVN::Dump::Snapshot::Dir->new(revision => $revision);
		$change = SVN::Dump::Change::Mkdir->new(
			path      => $path,
			analysis  => $self->get_analysis_then($revision, $path),
			entity    => $self->get_entity_then($revision, $path),
		);
	}
	elsif ($kind eq "file") {
		$node = SVN::Dump::Snapshot::File->new(
			revision  => $revision,
		);
		$change = SVN::Dump::Change::Mkfile->new(
			path      => $path,
			content   => $content,
			analysis  => $self->get_container_analysis_then($revision, $path),
			entity    => $self->get_container_entity_then($revision, $path),
		);
	}
	else {
		die "strange kind: $kind";
	}

	$self->pending_revision()->push_change($change);
}

# A change has copied a node to a new location.

sub copy_node {
	my ($self, $src_rev, $src_path, $revision, $dst_path, $kind, $data) = @_;

	my ($src_analysis_method, $src_entity_method);
	if ($kind eq "file") {
		$src_analysis_method  = "get_container_analysis_then";
		$src_entity_method    = "get_container_entity_then";
	}
	else {
		$src_analysis_method  = "get_analysis_then";
		$src_entity_method    = "get_entity_then";
	}

	my $change_class = "SVN::Dump::Change::Cp$kind";
	$self->pending_revision()->push_change(
		$change_class->new(
			analysis      => $self->get_analysis_then($revision, $dst_path),
			entity        => $self->get_entity_then($revision, $dst_path),
			path          => $dst_path,
			content       => $data,
			src_analysis  => $self->$src_analysis_method($src_rev, $src_path),
			src_entity    => $self->$src_entity_method($src_rev, $src_path),
			src_path      => $src_path,
			src_rev       => $src_rev,
		)
	);
}

# An operation has touched a node.  The node's containers all the way
# back to the repository root are also touched.

sub touch_node {
	my ($self, $revision, $path, $kind, $content) = @_;

	# Some changes don't alter content.  We'll skip them, since most
	# Subversion properties aren't portable.
	if (defined $content) {
		$self->pending_revision()->push_change(
			SVN::Dump::Change::Edit->new(
				path      => $path,
				content   => $content,
				analysis  => $self->get_container_analysis_then($revision, $path),
				entity    => $self->get_container_entity_then($revision, $path),
			)
		);
	}
}

# A change has deleted a node.
# Buffer the operation in the current revision for subsequent replay.
# Also track the deletion in the replay snapshot.

sub delete_node {
	my ($self, $path, $revision) = @_;

	# Succeeds if directory.
	my $analysis = $self->get_analysis_then($revision, $path);

	my ($entity, $deletion_class);
	if ($analysis) {
		$deletion_class = "SVN::Dump::Change::Rmdir";
		$entity = $self->get_entity_then($revision, $path);
	}
	else {
		$deletion_class = "SVN::Dump::Change::Rmfile";
		$analysis = $self->get_container_analysis_then($revision, $path);
		$entity = $self->get_container_entity_then($revision, $path);
	}

	$self->pending_revision()->push_change(
		$deletion_class->new(
			path      => $path,
			analysis  => $analysis,
			entity    => $entity,
		)
	);

	return;
}

###################
### Helper methods.

# Return the current entity at a path, or undef if none is there.
# TODO - Determine need.
# TODO - May be part of the old analysis code.
# TODO - May need to be refactored into the new analysis class.

sub get_entity {
	my ($self, $revision, $path) = @_;
	return $self->analysis()->get_entity_then($revision, $path);
}

sub get_container_entity_then {
	my ($self, $revision, $path) = @_;
	$path =~ s!/+[^/]*/*$!!;
	return $self->analysis()->get_entity_then($revision, $path);
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

sub get_container_analysis_then {
	my ($self, $revision, $path) = @_;
	$path =~ s!/+[^/]+/*$!!;
	return $self->analysis()->get_path_change_then($revision, $path);
}

sub get_analysis_then {
	my ($self, $revision, $path) = @_;
	return $self->analysis()->get_path_change_then($revision, $path);
}

sub get_entity_then {
	my ($self, $revision, $path) = @_;
	return $self->analysis()->get_entity_then($revision, $path);
}

sub map_entity_names {
	my ($self, $entity_name_map) = @_;
	$self->analysis()->map_entity_names($entity_name_map);
}

sub get_copy_sources {
	my ($self, $revision) = @_;
	return $self->analysis()->get_copy_sources_then($revision);
}

sub get_copy_source_then {
	my ($self, $revision, $path) = @_;
	return $self->analysis()->get_copy_source_then($revision, $path);
}

sub get_all_copy_sources {
	my $self = shift;
	return $self->analysis()->copy_sources();
}

1;
