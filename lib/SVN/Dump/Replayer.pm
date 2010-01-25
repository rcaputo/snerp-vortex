package SVN::Dump::Replayer;

# Replay a Subversion dump.

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Dump::Arborist;
use File::Copy;
use Cwd;
use Carp qw(croak);
use Digest::MD5 qw(md5_hex);

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

has copy_source_depot => (
	is        => 'ro',
	isa       => 'Str',
	required  => 1,
);

### High-level tracking.

sub on_branch_directory_creation {
	my ($self, $change) = @_;

	# Branch creation is a higher-order form of directory creation.
	$self->on_directory_creation($change);
}

sub on_branch_directory_copy {
	my ($self, $change) = @_;

	# Branch creation via directory copy is essentially just a directory
	# copy with additional implications.
	$self->on_directory_copy($change);
}

#sub on_branch_destruction { undef }

#sub on_branch_rename { undef }

sub on_tag_creation {
	my ($self, $change) = @_;

	# Tag creation is a side effect of directory creation.
	$self->on_directory_creation($change);

	# TODO - Verify the source exists and is a directory.
	# TODO - Verify the destination doesn't yet exist.
	# TODO - Verify the destination's parent directory exists and is a dir.
	# TODO - Copy the source to the destination.
}

#sub on_tag_destruction { undef }

#sub on_tag_rename { undef }

sub on_file_creation {
	my ($self, $change) = @_;

	my $full_path = $self->qualify_path($change);
	die "create $full_path failed: file already exists" if -e $full_path;

	open my $fh, ">", $full_path or die "create $full_path failed: $!";
	print $fh $change->content();
	close $fh;
}

sub on_file_change {
	my ($self, $change) = @_;
	# TODO - Find the absolute file path.
	# TODO - Update the file.
}

sub on_file_deletion {
	my ($self, $change) = @_;

	my $full_path = $self->qualify_path($change);
	die "delete $full_path failed: file doesn't exist" unless -e $full_path;
	die "delete $full_path failed: path not to a file" unless -f $full_path;

	unlink $full_path or die "unlink $full_path failed: $!";
}

sub on_file_copy {
	my ($self, $change) = @_;

	my ($copy_src_descriptor, $copy_src_path) = $self->generate_copy_source(
		$change
	);

	unless (-e $copy_src_path) {
		die "cp source $copy_src_path ($copy_src_descriptor) doesn't exist";
	}

	my $full_dst_path = $self->qualify_dst_path($change);
	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	copy($copy_src_path, $full_dst_path) or die(
		"cp $copy_src_path $full_dst_path failed: $!"
	);
}

#sub on_file_rename { undef }

sub on_directory_creation {
	my ($self, $change) = @_;

	my $full_path = $self->qualify_path($change);
	die "mkdir $full_path failed: directory already exists" if -e $full_path;

	mkdir $full_path or die "mkdir $full_path failed: $!";
}

sub on_directory_deletion {
	my ($self, $change) = @_;

	my $full_path = $self->qualify_path($change);
	die "rmdir $full_path failed: directory doesn't exist" unless -e $full_path;
	die "rmdir $full_path failed: path not to a directory" unless -d $full_path;

	rmdir $full_path or die "rmdir $full_path failed: $!";
	# TODO - Find absolute directory path.
	# TODO - Make sure directory exists and is a directory.
	# TODO - Remove directory.
}

sub on_directory_copy {
	my ($self, $change) = @_;

	my ($copy_src_descriptor, $copy_src_path) = $self->generate_copy_source(
		$change
	);

	# Directory copy sources are tarballs.
	$copy_src_path .= ".tar.gz";

	unless (-e $copy_src_path) {
		die "cp source $copy_src_path ($copy_src_descriptor) doesn't exist";
	}

	my $full_dst_path = $self->qualify_dst_path($change);
	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	# Make the target path.
	mkdir($full_dst_path) or die "mkdir $full_dst_path failed: $!";

	$self->do_mkdir($full_dst_path);
	$self->push_dir($full_dst_path);
	my $cwd = cwd();
	chdir($full_dst_path) or die "chdir $full_dst_path failed: $!";

	$self->do_or_die("tar", "xzf", $copy_src_path);
	$self->pop_dir();

	copy($copy_src_path, $full_dst_path) or die(
		"cp $copy_src_path $full_dst_path failed: $!"
	);
	# TODO - Find absolute source directory path.
	# TODO - Validate source exists and is a directory.
	# TODO - Find absolute destination directory path.
	# TODO - Do the copy.  May involve an untar.
}

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

		my $operation = $change->operation();

		# Change is a container.  Perhaps something is tagged or branched?
		if ($change->is_container()) {
			my $container_type = $change->container()->type();

			if ($container_type eq "branch") {
				$operation = "branch_$operation";
			}
			elsif ($container_type eq "tag") {
				$operation = "tag_$operation";
			}
			elsif ($container_type eq "meta") {
				# TODO - Do nothing?
			}
			else {
				die "unexpected container type: $container_type";
			}
		}

		# Change to a non-container is easy.
		my $method = "on_$operation";
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

### Helper methods.  TODO - Might belong in subclasses.

sub qualify_path {
	my ($self, $change) = @_;

	my $full_path = $self->svn_replay_base() . "/" . $change->path();
	$full_path =~ s!//+!/!g;

	return $full_path;
}

sub generate_copy_source {
	my ($self, $change) = @_;

	my $copy_source_descriptor = $change->src_path() . " " . $change->src_rev();

	my $full_copy_source = (
		$self->copy_source_depot() . "/" .
		md5_hex($copy_source_descriptor)
	);

	$full_copy_source =~ s!//+!/!g;

	return($copy_source_descriptor, $full_copy_source);
}

sub do_or_die {
  my $self = shift;
  print time() - $^T, " @_\n";
  system @_ and croak "system(@_) = ", ($? >> 8);
  return;
}

sub do_mkdir {
	my ($self, $directory) = @_;
	print time() - $^T, " mkdir $directory\n";
	mkdir $directory or croak "mkdir $directory failed: $!";
	return;
}

sub push_dir {
  my ($self, $new_dir) = @_;

  push @{$self->directory_stack()}, cwd();
	print time() - $^T, " pushdir $new_dir\n";
  chdir($new_dir) or croak "chdir $new_dir failed: $!";

  return;
}

sub pop_dir {
  my $self = shift;
  my $old_dir = pop @{$self->directory_stack()};
  print time() - $^T, " popdir $old_dir\n";
  chdir($old_dir) or croak "popdir failed: $!";
  return;
}

1;
