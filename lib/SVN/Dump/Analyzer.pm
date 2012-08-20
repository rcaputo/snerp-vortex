package SVN::Dump::Analyzer;

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Analysis;

use Carp qw(croak);
use Storable qw(dclone);

use Log::Any qw($log);

has analysis => (
	is      => 'rw',
	isa     => 'SVN::Analysis',
	lazy    => 1,
	default => sub {
		my $self = shift;
		my $analysis = SVN::Analysis->new(
			verbose => $self->verbose(),
			db_file_name => $self->db_file_name(),
		);
		$analysis->reset();
		return $analysis;
	},
);

has db_file_name => (
	is        => 'ro',
	isa       => 'Str',
	required  => 1,
);

has verbose => ( is => 'ro', isa => 'Bool', default => 0 );

#######################################
### 1st walk: Analyze branch lifespans.

sub on_node_add {
	my ($self, $revision, $path, $kind, $data) = @_;
	$log->trace("r$revision add $kind $path");
	$self->analysis()->consider_add($path, $revision, $kind);
}

sub on_node_change {
	my ($self, $revision, $path, $kind, $data) = @_;
	$log->trace("r$revision edit $kind $path");
	$self->analysis()->consider_change($path, $revision, $kind);
}

# According to the Red Bean Subersion book, "replacement" happens when
# a node is scheduled for deletion and addition in the same commit.
# As of svn 1.6.6 I'm not sure how to do this for a directory.  Maybe
# older versions permitted it?
# TODO - We may need a special "replace" operation if having deletion
# and addition in the same revision is confusing.
sub on_node_replace {
	my ($self, $revision, $path, $kind, $data) = @_;
	$log->trace("r$revision replace $kind $path");
	$self->analysis()->consider_delete($path, $revision);
	$self->analysis()->consider_add($path, $revision, $kind);
}

sub on_node_copy {
	my ($self, $dst_rev, $dst_path, $kind, $src_rev, $src_path, $text) = @_;
	$log->trace("r$dst_rev copy $kind $dst_path from $src_path at r$src_rev");
	$self->analysis()->consider_copy(
		$dst_path, $dst_rev, $kind, $src_path, $src_rev,
	);
}

sub on_node_delete {
	my ($self, $revision, $path) = @_;
	$log->trace("r$revision delete $path");
	$self->analysis()->consider_delete($path, $revision);
}

sub on_walk_done {
	my $self = shift;
	$self->analysis()->analyze();
}

sub on_walk_begin {
	my $self = shift;

	$log->trace("r0 add dir /");

	# The repository needs a root directory.
	$self->analysis()->consider_add("", 0, "dir");
}

1;
