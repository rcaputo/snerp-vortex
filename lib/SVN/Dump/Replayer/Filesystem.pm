package SVN::Dump::Replayer::Filesystem;

use Moose;
extends 'SVN::Dump::Replayer';

### Map high-level operations to a filesystem.

sub on_branch_directory_creation {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
}

sub on_tag_directory_creation {
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

	my $full_dst_path = $self->qualify_change_path($change);

	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		"none", $change
	);

	unless (-e $copy_depot_path) {
		die "cp source $copy_depot_path ($copy_depot_descriptor) doesn't exist";
	}

	# Weirdly, the copy source may not be authoritative.
	if (defined $change->content()) {
		$self->write_change_data($change, $full_dst_path);
		return;
	}

	# If content isn't provided, however, copy the file from the depot.
	$self->copy_file_or_die($copy_depot_path, $full_dst_path);
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

sub on_branch_rename {
	my ($self, $change, $revision) = @_;
	$self->do_rename($change);
}

sub on_tag_rename {
	my ($self, $change, $revision) = @_;
	$self->do_rename($change);
}

sub do_directory_copy {
	my ($self, $change, $full_dst_path) = @_;

	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		"none", $change
	);

	# Directory copy sources are tarballs.
	$copy_depot_path .= ".tar.gz";

	unless (-e $copy_depot_path) {
		die "cp source $copy_depot_path ($copy_depot_descriptor) doesn't exist";
	}

	$self->do_mkdir($full_dst_path);
	$self->push_dir($full_dst_path);
	$self->do_or_die("tar", "xzf", $copy_depot_path);
	$self->pop_dir();
}

### Mid-level tracking.

after on_walk_begin => sub {
  my $self = shift;

	# Reset the replay directory.
	$self->do_rmdir($self->replay_base()) if -e $self->replay_base();
	$self->do_mkdir($self->replay_base());
};

after on_revision_done => sub {
	my ($self, $revision_id) = @_;

	# TODO - After also doing the git version, consider how we'll
	# abstract this code back into Arborist to minimize per-VCS code.

	# Changes are done.  Remember any copy sources that pull from this
	# revision.
	COPY: foreach my $copy (
		map { @$_ }
		values %{$self->arborist()->copy_sources()->{$revision_id} || {}}
	) {
		my ($copy_depot_descriptor, $copy_depot_path) =
			$self->calculate_depot_info(
				"none", $copy->src_path(), $copy->src_revision()
			);

		# Tags don't necessarily exist.
		# TODO - However, this is a per-VCS behavior, so the decision
		# belongs in a per-VCS subclass.
		# TODO - Arborist::on_walk_done might be able to remove defunct
		# copy sources so they never appear here.
		my $src_entity = $self->arborist()->get_entity(
			$copy->src_path(), $revision_id,
		);

		my $copy_src_path = $self->calculate_path($copy->src_path());

		$self->log("CPY) Copy from entity $src_entity");
		$self->log("CPY) Copy from type ", $src_entity->type()) if $src_entity;

		die "copy source path $copy_src_path doesn't exist" unless (
			-e $copy_src_path
		);

		if (-d $copy_src_path) {
			$self->push_dir($copy_src_path);
			$self->do_or_die("tar", "czf", "$copy_depot_path.tar.gz", ".");
			$self->pop_dir();
			next COPY;
		}

		$self->copy_file_or_die($copy_src_path, $copy_depot_path);
		next COPY;
	}
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
