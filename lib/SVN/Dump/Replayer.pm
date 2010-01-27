package SVN::Dump::Replayer;

# Replay a Subversion dump.

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Dump::Arborist;
use File::Copy;
use File::Path;
use Cwd;
use Carp qw(confess);
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

has directory_stack => (
	is      => 'rw',
	isa     => 'ArrayRef[Str]',
	default => sub { [] },
);

### High-level tracking.

sub on_branch_directory_creation {
	my ($self, $change) = @_;
	$self->do_mkdir($self->qualify_svn_path($change));
}

sub on_branch_directory_copy {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_svn_path($change));
}

sub on_tag_directory_copy {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_svn_path($change));
}

sub on_file_creation {
	my ($self, $change) = @_;
	$self->write_new_file($change, $self->qualify_svn_path($change));
}

sub on_file_change {
	my ($self, $change) = @_;
	$self->rewrite_file($change, $self->qualify_svn_path($change));
}

sub on_file_deletion {
	my ($self, $change) = @_;
	$self->do_file_deletion($self->qualify_svn_path($change));
}

sub on_file_copy {
	my ($self, $change) = @_;
	$self->do_file_copy($change, $self->qualify_svn_path($change));
}

sub on_directory_creation {
	my ($self, $change) = @_;
	$self->do_mkdir_safely($self->qualify_svn_path($change));
}

sub on_directory_deletion {
	my ($self, $change) = @_;
	$self->do_rmdir_safely($self->qualify_svn_path($change));
}

sub on_directory_copy {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_svn_path($change));
}

### Low-level tracking.

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

	# Changes are done.  Remember any copy sources that pull from this
	# revision.

	COPY: foreach my $copy (
		values %{$self->arborist()->copy_sources()->{$revision_id} || {}}
	) {
		my ($copy_depot_descriptor, $copy_depot_path) = $self->calculate_depot_info(
			$copy->src_path(), $copy->src_revision()
		);

		my $copy_src_path = $self->calculate_svn_path($copy->src_path());
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

	undef;
}

sub on_node_change {
	my ($self, $revision, $path, $kind, $data) = @_;

	my $entity = $self->arborist()->get_historical_entity($revision, $path);

	if ($entity->type() ne "branch") {
		die $entity->debug("$path @ $revision changed outside a branch: %s");
	}

	$self->arborist()->touch_node($path, $kind, $data);

	# TODO - Do we need the following code?
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
	$self->arborist()->copy_node(
		$from_rev, $from_path, $revision, $path, $kind, $data
	);

	# TODO - Need this?
#	if ($path eq $d_entity->path()) {
#		my $s_entity = $self->arborist()->get_historical_entity(
#			$from_rev, $from_path
#		);
#
##		print(
##			"copying to $kind $path (", $s_entity->type(), " ",
##			$s_entity->name(), ") ... creating ",
##			$d_entity->type(), " ", $d_entity->name(), "\n"
##		);
#
##		if ($d_entity->type() eq "branch") {
##			$self->on_branch_creation($s_entity->name(), $d_entity->name());
##			return;
##		}
##
##		if ($d_entity->type() eq "tag") {
##			$self->on_tag_creation($s_entity->name(), $d_entity->name());
##			return;
##		}
##
##		die $d_entity->debug("unexpected entity: %s");
#	}

	undef;
}

### Helper methods.  TODO - Might belong in subclasses.

sub qualify_svn_path {
	my ($self, $change) = @_;
	return $self->calculate_svn_path($change->path());
}

sub calculate_svn_path {
	my ($self, $path) = @_;

	my $full_path = $self->svn_replay_base() . "/" . $path;
	$full_path =~ s!//+!/!g;

	return $full_path;
}

sub get_copy_depot_info {
	my ($self, $change) = @_;
	return $self->calculate_depot_info($change->src_path(), $change->src_rev());
}

sub calculate_depot_info {
	my ($self, $path, $revision) = @_;

	my $copy_depot_descriptor = "$path $revision";

	my $full_depot_path = (
		$self->copy_source_depot() . "/" .
		md5_hex($copy_depot_descriptor)
	);

	$full_depot_path =~ s!//+!/!g;

	return($copy_depot_descriptor, $full_depot_path);
}

### Action stuff.

sub do_or_die {
  my $self = shift;
	$self->log("@_");
  system @_ and confess "system(@_) = ", ($? >> 8);
  return;
}

sub do_mkdir {
	my ($self, $directory) = @_;
	$self->log("mkdir $directory");
	mkdir $directory or confess "mkdir $directory failed: $!";
	return;
}

sub do_rmdir {
	my ($self, $directory) = @_;
	$self->log("mrtree $directory");
	rmtree $directory or confess "rmtree $directory failed: $!";
	return;
}

sub push_dir {
  my ($self, $new_dir) = @_;

  push @{$self->directory_stack()}, cwd();
	$self->log("pushdir $new_dir");
  chdir($new_dir) or confess "chdir $new_dir failed: $!";

  return;
}

sub pop_dir {
  my $self = shift;
  my $old_dir = pop @{$self->directory_stack()};
	$self->log("popdir $old_dir");
  chdir($old_dir) or confess "popdir failed: $!";
  return;
}

sub copy_file_or_die {
	my ($self, $src, $dst) = @_;
	$self->log("copy $src $dst");
	copy($src, $dst) or confess "cp $src $dst failed: $!";
}

sub log {
	my $self = shift;
	print time() - $^T, " ", join("", @_), "\n";
}

sub do_directory_copy {
	my ($self, $change, $full_dst_path) = @_;

	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		$change
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

sub rewrite_file {
	my ($self, $change, $full_path) = @_;

	die "edit $full_path failed: file doesn't exist" unless -e $full_path;
	die "edit $full_path failed: path is not a file" unless -f $full_path;

	$self->log("changing file $full_path");

	$self->write_change_data($change, $full_path);
}

sub write_new_file {
	my ($self, $change, $full_path) = @_;

	die "create $full_path failed: file already exists" if -e $full_path;

	$self->log("creating file $full_path");

	$self->write_change_data($change, $full_path);
}

sub write_change_data {
	my ($self, $change, $full_path) = @_;
	open my $fh, ">", $full_path or die "create $full_path failed: $!";
	print $fh $change->content();
	close $fh;
}

sub do_file_deletion {
	my ($self, $full_path) = @_;

	die "delete $full_path failed: file doesn't exist" unless -e $full_path;
	die "delete $full_path failed: path not to a file" unless -f $full_path;

	$self->log("deleting file $full_path");

	unlink $full_path or die "unlink $full_path failed: $!";
}

sub do_file_copy {
	my ($self, $change, $full_dst_path) = @_;

	die "cp to $full_dst_path failed: path exists" if -e $full_dst_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		$change
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

sub do_rmdir_safely {
	my ($self, $full_path) = @_;
	die "rmtree $full_path failed: directory doesn't exist" unless -e $full_path;
	die "rmtree $full_path failed: path not to a directory" unless -d $full_path;
	$self->do_rmdir($full_path);
}

sub do_mkdir_safely {
	my ($self, $full_path) = @_;
	die "mkdir $full_path failed: path already exists" if -e $full_path;
	$self->do_mkdir($full_path);
}

1;
