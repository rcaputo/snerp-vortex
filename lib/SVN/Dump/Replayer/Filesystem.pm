package SVN::Dump::Replayer::Filesystem;

use Moose;
extends 'SVN::Dump::Replayer';

### Map high-level operations to a filesystem.

sub on_branch_directory_creation {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
}

sub on_branch_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
}

sub on_tag_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
}

sub on_file_creation {
	my ($self, $change, $revision) = @_;
	$self->write_new_file($change, $self->qualify_change_path($change));
}

sub on_file_change {
	my ($self, $change, $revision) = @_;
	$self->rewrite_file($change, $self->qualify_change_path($change));
}

sub on_file_deletion {
	my ($self, $change, $revision) = @_;
	$self->do_file_deletion($self->qualify_change_path($change));
}

sub on_file_copy {
	my ($self, $change, $revision) = @_;
	$self->do_file_copy($change, $self->qualify_change_path($change));
}

sub on_directory_creation {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
}

sub on_directory_deletion {
	my ($self, $change, $revision) = @_;
	$self->do_rmdir_safely($self->qualify_change_path($change));
}

sub on_branch_directory_deletion {
	my ($self, $change, $revision) = @_;
	$self->do_rmdir_safely($self->qualify_change_path($change));
}

sub on_tag_directory_deletion {
	my ($self, $change, $revision) = @_;
	$self->do_rmdir_safely($self->qualify_change_path($change));
}

sub on_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
}

sub on_rename {
	my ($self, $change, $revision) = @_;
	$self->do_rename($change);
}

sub on_tag_rename {
	my ($self, $change, $revision) = @_;
	$self->do_rename($change);
}

### Mid-level tracking.

after on_walk_begin => sub {
  my $self = shift;

	# Reset the replay directory.
	$self->do_rmdir($self->replay_base()) if -e $self->replay_base();
	$self->do_mkdir($self->replay_base());
};

### Low-level helpers.

sub qualify_change_path {
	my ($self, $change) = @_;
	return $self->calculate_path($change->path());
}

sub calculate_path {
	my ($self, $path) = @_;

	my $full_path = $self->replay_base() . "/" . $path;
	$full_path =~ s!//+!/!g;

	return $full_path;
}

1;
