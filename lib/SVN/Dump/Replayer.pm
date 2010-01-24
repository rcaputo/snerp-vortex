package SVN::Dump::Replayer;

# Replay a Subversion dump.

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Dump::Arborist;

has arborist => (
	is => 'ro',
	isa => 'SVN::Dump::Arborist',
	lazy => 1,
	default => sub {
		my $self = shift;
		return SVN::Dump::Arborist->new(
			svn_dump_filename => $self->svn_dump_filename()
		)->walk();
	},
);

has svn_replay_base => (
	is        => 'ro',
	isa       => 'Str',
	required  => 1,
);

### High-level tracking.

## ($self, $branch_name)
sub on_branch_creation {
	my ($self, $change) = @_;
	# TODO - Verify the source exists and is a directory.
	# TODO - Verify the destination doesn't yet exist.
	# TODO - Verify the destination's parent directory exists and is a dir.
	# TODO - Copy the source to the destinatin.
}

## ($self, $branch_name)
#sub on_branch_destruction { undef }
#
## ($self, $old_branch_name, $new_branch_name)
#sub on_branch_rename { undef }

## ($self, $branch_name, $tag_name)
sub on_tag_creation {
	my ($self, $change) = @_;
	# TODO - Verify the source exists and is a directory.
	# TODO - Verify the destination doesn't yet exist.
	# TODO - Verify the destination's parent directory exists and is a dir.
	# TODO - Copy the source to the destination.
}

## ($self, $tag_name)
#sub on_tag_destruction { undef }
#
## ($self, $branch_name, $tag_name)
#sub on_tag_rename { undef }

## ($self, $branch_name, $file_path, $file_content)
sub on_file_creation {
	my ($self, $change) = @_;
	# TODO - Find the absolute file path.
	# TODO - Create the file.
}

## ($self, $branch_name, $file_path, $file_content)
sub on_file_change {
	my ($self, $change) = @_;
	# TODO - Find the absolute file path.
	# TODO - Update the file.
}

## ($self, $branch_name, $file_path)
sub on_file_deletion {
	my ($self, $change) = @_;
	# TODO - Find absolute file path.
	# TODO - Verify that the file exists and is a file.
	# TODO - Delete the file.
}

## ???
sub on_file_copy {
	my ($self, $change) = @_;
	# TODO - Find absolute source file path.
	# TODO - Validate that source file exists and is a file.
	# TODO - Find absolute destination file path.
	# TODO - Copy the file.  May involve the temporary copy source repot.
}

## ($self, $branch_name, $old_file_path, $new_file_path)
#sub on_file_rename { undef }

## ($self, $branch_name, $directory_path)
sub on_directory_creation {
	my ($self, $change) = @_;
	# TODO - Find the absolute directory path.
	# TODO - Create the directory.
}

## ($self, $branch_name, $directory_path)
sub on_directory_deletion {
	my ($self, $change) = @_;
	# TODO - Find absolute directory path.
	# TODO - Make sure directory exists and is a directory.
	# TODO - Remove directory.
}

## ???
sub on_directory_copy {
	my ($self, $change) = @_;
	# TODO - Find absolute source directory path.
	# TODO - Validate source exists and is a directory.
	# TODO - Find absolute destination directory path.
	# TODO - Do the copy.  May involve an untar.
}

## ($self, $branch_name, $old_directory_path, $new_directory_path)
#sub on_directory_rename { undef }

### Low-level tracking.

#lib/SVN/Dump/Change/Cpdir.pm
#lib/SVN/Dump/Change/Cpfile.pm
#lib/SVN/Dump/Change/Delete.pm
#lib/SVN/Dump/Change/Edit.pm
#lib/SVN/Dump/Change/Mkdir.pm
#lib/SVN/Dump/Change/Mkfile.pm

sub on_revision_done {
	my ($self, $revision_id) = @_;

	my $revision = $self->arborist()->finalize_revision();
	CHANGE: foreach my $change (@{$revision->changes()}) {

		# Change is a container.  Perhaps something is tagged or branched?
		if ($change->is_container()) {
			my $container_type = $change->container()->type();
			my $container_name = $change->container()->name();

			if ($container_type eq "branch") {
				$self->on_branch_creation($change);
			}
			elsif ($container_type eq "tag") {
				$self->on_tag_creation($change);
			}
			elsif ($container_type eq "meta") {
				$self->on_directory_creation($change);
			}
			else {
				die "unexpected container type: $container_type";
			}

			next CHANGE;
		}

		# Change to a non-container is easy.
		my $method = $change->callback();
		$self->$method($change);
	}

	undef;
}

sub on_revision {
	my ($self, $revision, $author, $date, $log_message) = @_;

	print "r$revision by $author at $date\n";

	$log_message = "(none)" unless defined($log_message) and length($log_message);
	chomp $log_message;

	$self->arborist()->start_revision($revision, $author, $date, $log_message);

	undef;
}

sub on_node_add {
	my ($self, $revision, $path, $kind, $data) = @_;

	$self->arborist()->add_new_node($revision, $path, $kind, $data);

	my $entity = $self->arborist()->get_historical_entity($revision, $path);

	unless (defined $entity) {
		die "adding $kind $path in unknown entity";
	}

	# TODO - Push the pending operation onto the branch.

	if ($entity->path() eq $path) {
		print(
			"adding $kind $path ... creating ",
			$entity->type(), " ", $entity->name(), "\n"
		);
	}


	undef;
}

sub on_node_change {
	my ($self, $revision, $path, $kind, $data) = @_;

	my $entity = $self->arborist()->get_historical_entity($revision, $path);

	if ($entity->type() ne "branch") {
		die $entity->debug("$path @ $revision changed outside a branch: %s");
	}

	$self->arborist()->touch_node($path, $kind, $data);

#	# Push the pending operation onto the branch.
#
#	if ($kind eq "file") {
#		$self->on_file_change($entity->name(), $path, $data);
#		return;
#	}
#
#	# Mode changes are ignored.
#	if ($kind eq "dir") {
#		return;
#	}

	#die "$path @ $revision is unexpected kind '$kind'";
}

sub on_node_delete {
	my ($self, $revision, $path) = @_;

	my $deleted = $self->arborist()->delete_node($path);
	my $kind = $deleted->{kind};

	# TODO - Push the deletion onto the branch.

	undef;
}

sub on_node_copy {
	my ($self, $revision, $path, $kind, $from_rev, $from_path, $data) = @_;

	my $d_entity = $self->arborist()->get_historical_entity($revision, $path);

	unless ($d_entity) {
		die "copying $kind $from_path to $path at $revision in unexpected entity";
	}

	# TODO - Complex.  See walk-svn.pl for starters.
	$self->arborist()->copy_node($from_rev, $from_path, $revision, $path, $kind);

	if ($path eq $d_entity->path()) {
		my $s_entity = $self->arborist()->get_historical_entity(
			$from_rev, $from_path
		);

#		print(
#			"copying to $kind $path (", $s_entity->type(), " ",
#			$s_entity->name(), ") ... creating ",
#			$d_entity->type(), " ", $d_entity->name(), "\n"
#		);

#		if ($d_entity->type() eq "branch") {
#			$self->on_branch_creation($s_entity->name(), $d_entity->name());
#			return;
#		}
#
#		if ($d_entity->type() eq "tag") {
#			$self->on_tag_creation($s_entity->name(), $d_entity->name());
#			return;
#		}
#
#		die $d_entity->debug("unexpected entity: %s");
	}

	undef;
}

1;
