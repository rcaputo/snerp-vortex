package SVN::Dump::Replayer;

# Replay a Subversion dump.  Must be subclassed with something classy.

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
			svn_dump_filename => $self->svn_dump_filename(),
			verbose           => $self->verbose(),
			path_prefix       => $self->path_prefix(),
		)->walk();
	},
);

has verbose => ( is => 'ro', isa => 'Bool', default => 0 );

# Replays go somewhere.  Optional because we might replay somewhere
# dissociated from a filesystem.
has replay_base => (
	is        => 'ro',
	isa       => 'Str',
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

has path_prefix => (
	is	=> 'ro',
	isa	=> 'Str',
	default	=> '',
);

### Low-level tracking.

sub on_walk_begin {
	my $self = shift;

	$self->do_rmdir($self->copy_source_depot()) if -e $self->copy_source_depot();
	$self->do_mkdir($self->copy_source_depot());
}

sub on_revision_done {
	my ($self, $revision_id) = @_;

	my $revision = $self->arborist()->finalize_revision();
	CHANGE: foreach my $change (@{$revision->changes()}) {

		my $operation = $change->operation();

		$self->log("REP) $operation ", $change->path());
		$self->log(
			"REP) ", ($change->is_container() ? "is" : "is not"), " container"
		);
		$self->log(
			$change->container()->type(), " ", $change->container()->name()
		);

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
		$self->log("REP) calling method $method");
		$self->$method($change, $revision);
	}

	# Changes are done.  Remember any copy sources that pull from this
	# revision.
	COPY: foreach my $copy (
		map { @$_ }
		values %{$self->arborist()->copy_sources()->{$revision_id} || {}}
	) {
		my ($copy_depot_descriptor, $copy_depot_path) = $self->calculate_depot_info(
			$copy->src_path(), $copy->src_revision()
		);

		my $copy_src_path = $self->calculate_path($copy->src_path());

		# Tags don't necessarily exist.
		# TODO - However, this is a per-SCM behavior, so the decision
		# belongs in a per-SCM subclass.
		# TODO - Arborist::on_walk_done might be able to remove defunct
		# copy sources so they never appear here.
		my $src_entity = $self->arborist()->get_entity(
			$copy->src_path(), $revision_id,
		);

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

	undef;
}

sub on_revision {
	my ($self, $revision, $author, $date, $log_message) = @_;

	$self->log("r$revision by $author at $date");

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

	if ($entity->type() ne "branch" and $entity->type() ne "meta") {
		die $entity->debug("$path @ $revision changed outside a branch: %s");
	}

	$self->arborist()->touch_node($path, $kind, $data);
}

# I'm led to believe that node-action "replace" is another form of
# node-action "change".  This method exists as a hook for subclasses
# to do something different.
sub on_node_replace {
	goto &on_node_change;
}

sub on_node_delete {
	my ($self, $revision, $path) = @_;

	my $deleted = $self->arborist()->delete_node($path, $revision);
	my $kind = $deleted->{kind};

	# TODO - Push the deletion onto the branch?

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

	undef;
}

### Helper methods.  TODO - Might belong in subclasses.

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

sub pipe_into_or_die {
	my ($self, $data, $cmd) = @_;
	$self->log($cmd);
	open my $fh, "|-", $cmd or die $!;
	print $fh $data;
	close $fh;
	return;
}

sub pipe_out_of_or_die {
	my ($self, $cmd) = @_;
	$self->log($cmd);
	open my $fh, "-|", $cmd or die $!;
	local $/;
	my $data = <$fh>;
	close $fh;
	return $data;
}

# Returns true if success.
sub do_sans_die {
  my $self = shift;
	$self->log("@_");
  return !(system @_);
}

sub do_mkdir {
	my ($self, $directory) = @_;
	$self->log("mkdir $directory");
	mkdir $directory or confess "mkdir $directory failed: $!";
	return;
}

sub do_rmdir {
	my ($self, $directory) = @_;
	$self->log("rmtree $directory");
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
	return unless $self->verbose();
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

  # File may not actually be changing.  The subversion change may only
  # be to properties, which we don't care about here.  Only bother
	# checking if the file sizes are equal; saves a lot of I/O that way.

	if ((-s $full_path) == do { use bytes; length($change->content()) }) {
    open my $fh, "<", $full_path or die $!;
    local $/;
    my $current_text = <$fh>;
    if ($current_text eq $change->content()) {
			$self->log("skipping rewrite - file didn't change");
			return;
    }
  }

	$self->log("changing file $full_path");
	$self->write_change_data($change, $full_path);

	return 1;
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

sub do_rename {
	my ($self, $change) = @_;

	my $full_src_path = $self->calculate_path($change->src_path());
	my $full_dst_path = $self->calculate_path($change->path());

	rename $full_src_path, $full_dst_path or die(
		"rename $full_src_path $full_dst_path failed: $!"
	);
}

### Virtual methods to override.

sub on_branch_directory_copy { confess "must override method"; }
sub on_branch_directory_creation { confess "must override method"; }
sub on_branch_directory_deletion { confess "must override method"; }
sub on_branch_rename { confess "must override method"; }

sub on_directory_copy { confess "must override method"; }
sub on_directory_creation { confess "must override method"; }
sub on_directory_deletion { confess "must override method"; }
sub on_directory_rename { confess "must override method"; }

sub on_file_change { confess "must override method"; }
sub on_file_copy { confess "must override method"; }
sub on_file_creation { confess "must override method"; }
sub on_file_deletion { confess "must override method"; }
sub on_file_rename { confess "must override method"; }

sub on_tag_directory_copy { confess "must override method"; }
sub on_tag_directory_deletion { confess "must override method"; }
sub on_tag_rename { confess "must override method"; }

sub on_rename { confess "must override method"; }

1;
