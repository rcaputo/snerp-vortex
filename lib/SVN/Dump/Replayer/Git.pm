package SVN::Dump::Replayer::Git;

{
	# TODO - Refactor into its own class?
	# It feels odd making an entire class for a data structure.
	package SVN::Dump::Replayer::Git::Author;
	use Moose;
	has name  => ( is => 'ro', isa => 'Str', required => 1 );
	has email => ( is => 'ro', isa => 'Str', required => 1 );
	1;
}

{
	# TODO - Refactor into its own class?
	# It feels odd making an entire class for a data structure.
	package GitTag;
	use Moose;
	has revision => ( is => 'ro', isa => 'SVN::Dump::Revision', required => 1 );
}

use Moose;
extends 'SVN::Dump::Replayer';
use Carp qw(croak);
use File::Path qw(mkpath);

has authors_file    => ( is => 'ro', isa => 'Str' );
has authors => (
	is => 'rw',
	isa => 'HashRef[SVN::Dump::Replayer::Git::Author]',
);

has files_needing_add => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} }
);

has directories_needing_add => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} }
);

has needs_commit => ( is => 'rw', isa => 'Int', default => 0 );

has revisions_between_gc => ( is => 'ro', 'isa' => 'Int', default => 1000 );
has revisions_until_gc => ( is => 'rw', isa => 'Int', default => 1000 );

has tags => ( is => 'rw', isa => 'HashRef[GitTag]', default => sub { {} } );

has path_map => ( is => 'rw', isa => 'HashRef[Str]', default => sub { {} } );
has path_regex => ( is => 'rw', isa => 'RegexpRef' );
has current_branch => ( is => 'rw', isa => 'Str', default => '' );

{
	package SVN::Dump::Replayer::Git::CopySrc;
	use Moose;
	has git_rev => ( is => 'ro', isa => 'Str', required => 1 );
	has rel_path => ( is => 'ro', isa => 'Str', required => 1 );
}

###

after on_revision_done => sub {
	my ($self, $revision_id) = @_;
	my $final_revision = $self->arborist()->pending_revision();
	$self->git_commit($final_revision);

	# Changes are done.  Remember any copy sources that pull from this
	# revision.  For git, a copy source is a revision SHA1 and
	# branch-relative path.

	$self->push_dir($self->replay_base());

	COPY: foreach my $copy (
		map { @$_ }
		values %{$self->arborist()->copy_sources()->{$revision_id} || {}}
	) {
		$self->log($copy->debug("CPY) saving %s"));

		my $src_entity = $self->arborist()->get_historical_entity(
			$revision_id, $copy->src_path(),
		);

		# Sanity check.  Copy sources are always branches.
		# TODO - They could be tags, since tags are just references to
		# particular moments in time.
		confess $src_entity->type() unless $src_entity->type() eq "branch";

		my $branch = $src_entity->name();
		my $git_branch = ($branch eq "trunk") ? "master" : $branch;

		# The copy depot descriptor is a MD5 hex string describing the
		# source path and revision.  Git's replayer uses it as a key into
		# its hash-based copy depot.

		my ($copy_depot_descriptor, $copy_depot_path) =
			$self->calculate_depot_info(
				$git_branch, $copy->src_path(), $copy->src_revision()
			);

		my $copy_src_path = $copy->rel_src_path();

		$self->log(
			"CPY) Copy from ", $src_entity->type(), " ",
			$src_entity->name(), " ", $copy->src_path(), " at ",
			$copy->src_revision()
		);
		$self->log("CPY) descriptor = $copy_depot_descriptor");

		if ($git_branch ne $self->current_branch()) {
			$self->log("GIT) switching to branch $git_branch");
			$self->do_sans_die("git", "checkout", $git_branch);
			$self->current_branch($git_branch);
		}

		confess "copy source path $copy_src_path doesn't exist" unless (
			-e $copy_src_path
		);

		if (-d $copy_src_path) {
			$self->log(
				"CPY) Saving directory $copy_src_path in: $copy_depot_path.tar.gz"
			);
			$self->push_dir($copy_src_path);
			$self->do_or_die("tar", "czf", "$copy_depot_path.tar.gz", ".");
			$self->pop_dir();
			next COPY;
		}

		$self->log("CPY) Saving file $copy_src_path in: $copy_depot_path");
		$self->copy_file_or_die($copy_src_path, $copy_depot_path);
		next COPY;
	}

#trunk trunk 28: !!perl/hash:SVN::Dump::Replayer::Git::CopySrc 
#  git_rev: 9a69aff2a0a4d67afd317e2ba66545894464fc2c
#  rel_path: trunk

	$self->pop_dir();
};

# Before entity fixup, flag all source entities as modified, and
# convert them to branches if necessary.  This pins these "tags" to
# the filesystem, where they'll have files from which copies can be
# made.
# TODO - This all may become moot if we can copy from tags in git.
before on_walk_begin => sub {
	my $self = shift;

	my $copy_sources = $self->arborist()->copy_sources();
	while (my ($rev, $path_rec) = each %$copy_sources) {
		foreach my $path (keys %$path_rec) {
			my $entity = $self->arborist()->get_entity($path, $rev);
			next unless $entity;
			$entity->modified(1);
			$entity->type("branch");
		}
	}
};

after on_walk_begin => sub {
	my $self = shift;

	# Set up authors mapping.
	if (defined $self->authors_file()) {
		# Initialize it.  Probably can use Moose to tell us it's been set.
		$self->authors({});

		open my $fh, "<", $self->authors_file() or confess $!;
		while (<$fh>) {
			my ($nick, $name, $email) = (/^\s*([^=]*?)\s*=\s*([^<]*?)\s*<(\S+?)>/);

			$name = $nick unless defined $name and length $name;

			$self->authors()->{$nick} = SVN::Dump::Replayer::Git::Author->new(
				name  => $name,
				email => $email,
			);
		}
	}

	$self->do_rmdir($self->replay_base()) if -e $self->replay_base();
	$self->do_mkdir($self->replay_base());

	$self->push_dir($self->replay_base());
	$self->do_or_die("git", "init", ($self->verbose() ? () : ("-q")));
	$self->pop_dir();
};

sub on_branch_directory_creation {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());

	# Branch directories are always created out of master?
	$self->set_branch($revision, "master");
	#$self->set_branch($revision, $change->container());

	my $path = $change->rel_path();
	$self->do_mkdir($path);

	$self->pop_dir();
	# Git doesn't track directories, so nothing to add.
}

sub on_branch_directory_copy {
	my ($self, $change, $revision) = @_;

	# Branches must be created from containers.

	# TODO - Subversion supports "silly" things like branching and
	# tagging subdirectories within entities.
	# TODO - At the moment, the best we can do is tag or branch the
	# entire containing entity.
	# TODO - Consider identifying subdirectories that are treated like
	# sub-branches and mapping them to proper branches.  Then they can
	# be tagged as proper entities.

	#unless ($change->is_from_container()) {
	#	confess "source is not container";
	#}

	# TODO - This tells us how to map directories.
	# "GIT) creating branch from trunk to tags/v0_06".
	# From this point forward, all paths beginning with "tags/v0_06/"
	# become "trunk/".

	$self->log(
		"GIT) creating branch from ", $change->src_container->path(),
		" to ", $change->path()
	);

	$self->path_map()->{$change->path()} = $change->src_container->path();
	my $regexp = join(
		"|",
		map { quotemeta($_) }
		sort { (length($b) <=> length($a)) || ($a cmp $b) }
		keys %{$self->path_map()}
	);
	$self->path_regex(qr/$regexp/);

	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->src_container());
	$self->do_or_die(
		"git", "checkout", "-b", $change->container()->name()
	);
	$self->current_branch($change->container()->name());
	$self->pop_dir();
	return;

#	$self->do_directory_copy($change, $self->qualify_change_path($change));
#	$self->directories_needing_add()->{$change->rel_path()} = 1;
}

sub on_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	my $src_branch_name = $change->src_container()->name();
	$src_branch_name = "master" if $src_branch_name eq "trunk";

	#my $dst_path = $self->arborist()->calculate_relative_path($change->path());
	my $dst_path = $change->rel_path();

	$self->do_directory_copy($src_branch_name, $change, $dst_path);
	$self->directories_needing_add()->{$dst_path} = 1;
	$self->pop_dir();
}

sub on_directory_creation {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());
	$self->do_mkdir($change->rel_path());
	$self->pop_dir();
}

sub on_directory_deletion {
	my ($self, $change, $revision) = @_;

	# TODO - Doesn't need a commit if $rel_path is a directory that
	# contains no files.
	#   1. find $rel_path -type f
	#   2. If anything comes up, then we need a commit.
	#   3. Otherwise, we don't need one on account of this.

	# First try git rm, to remove from the repository.
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	my $rm_path = $change->rel_path();
	confess "can't remove nonexistent directory $rm_path" unless -e $rm_path;

	$self->git_env_setup($revision);

	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$rm_path,
	);

	# Second, try a plain filesystem remove in case the file hasn't yet
	# been staged.  Since git-rm may have removed any number of parent
	# directories for $rel_path, we only try to rmtree() if it still
	# exists.

	$self->do_rmdir($rm_path) if -e $rm_path;

	# Git cleans up directories; svn assumes they exist.
	$self->ensure_parent_dir_exists($rm_path);

	delete $self->directories_needing_add()->{$rm_path};
	$self->needs_commit(1);

	$self->pop_dir();
}

sub on_branch_directory_deletion {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());
	$self->git_env_setup($revision);
	$self->do_or_die(
		"git", "branch", "-D",
		$change->container()->name(),
	);
	$self->pop_dir();
}

sub on_file_change {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());
	my $rewrite_path = $change->rel_path();
	if ($self->rewrite_file($change, $rewrite_path)) {
		$self->files_needing_add()->{$rewrite_path} = 1;
	}
	$self->pop_dir();
}

sub on_file_copy {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	my $src_branch_name = $change->container()->name();
	$src_branch_name = "master" if $src_branch_name eq "trunk";

	my $dst_path = $change->rel_path();
	$self->do_file_copy($src_branch_name, $change, $dst_path);
	$self->files_needing_add()->{$dst_path} = 1;
	$self->pop_dir();
}

sub on_file_creation {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());
	my $create_path = $change->rel_path();
	$self->write_new_file($change, $create_path);
	$self->files_needing_add()->{$create_path} = 1;
	$self->pop_dir();
}

sub on_file_deletion {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	my $rm_path = $change->rel_path();
	confess "can't remove nonexistent file $rm_path" unless -e $rm_path;

	$self->git_env_setup($revision);

	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$rm_path,
	);

	# git-rm doesn't always remove the files right away.
	$self->do_rmdir($rm_path) if -e $rm_path;

	$self->ensure_parent_dir_exists($rm_path);
	$self->pop_dir();

	delete $self->files_needing_add()->{$rm_path};
	$self->needs_commit(1);
}

sub on_tag_directory_copy {
	my ($self, $change, $revision) = @_;

	$self->git_commit($revision);

	my $tag_name = $change->container()->name();
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->src_container());

	$self->git_env_setup($revision);

	$self->pipe_into_or_die($revision->message(), "git tag -a -F - $tag_name");
	$self->pop_dir();

	$self->log("TAG) setting tag $tag_name");
	$self->tags()->{$tag_name} = $revision;
}

sub on_tag_directory_creation {
	my ($self, $change, $revision) = @_;

	$self->git_commit($revision);

	my $tag_name = $change->container()->name();
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	$self->git_env_setup($revision);

	$self->pipe_into_or_die($revision->message(), "git tag -a -F - $tag_name");
	$self->pop_dir();

	$self->log("TAG) setting tag $tag_name");
	$self->tags()->{$tag_name} = $revision;
}

sub on_tag_directory_deletion {
	my ($self, $change, $revision) = @_;

	# Tag deletion is out of band.
	$self->push_dir($self->replay_base());
	$self->git_env_setup($revision);
	$self->do_or_die("git", "tag", "-d", $change->container()->name());
	$self->pop_dir();

	$self->log("TAG) deleting tag ", $change->container()->name());
	delete $self->tags()->{$change->container()->name()};
}

sub on_file_rename {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	confess "target of file rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or confess(
		"file rename from ", $change->src_path(),
		" to ", $change->path(),
		"failed: $!"
	);

	$self->ensure_parent_dir_exists($change->src_path());
	$self->pop_dir();
	$self->needs_commit(1);
}

sub on_rename {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	confess "target of rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or confess(
		"rename from ", $change->src_path(),
		" to ", $change->path(),
		"failed: $!"
	);

	$self->ensure_parent_dir_exists($change->src_path());
	$self->pop_dir();
	$self->needs_commit(1);
}

sub on_directory_rename {
	my ($self, $change, $revision) = @_;
	$self->push_dir($self->replay_base());
	$self->set_branch($revision, $change->container());

	confess "target of dir rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or confess(
		"directory rename from ", $change->src_path(),
		" to ", $change->path(),
		"failed: $!"
	);

	$self->ensure_parent_dir_exists($change->src_path());
	$self->pop_dir();
	$self->needs_commit(1);
}

sub on_branch_rename {
	my ($self, $change, $revision) = @_;

	if (0) {
		$self->push_dir($self->replay_base());
		$self->set_branch($revision, $change->container());

		confess "target of branch rename (", $change->path(), ") already exists" if (
			-e $change->path()
		);

		$self->git_env_setup($revision);

		$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
		rename($change->src_path(), $change->path()) or
		confess(
			"branch rename from ", $change->src_path(),
			" to ", $change->path(),
			" failed: $!"
		);

		$self->ensure_parent_dir_exists($change->src_path());
		$self->pop_dir();
		$self->needs_commit(1);
	}
	else {
		$self->push_dir($self->replay_base());
		$self->git_env_setup($revision);
		$self->do_or_die(
			"git", "branch", "-m",
			$change->src_container()->name(),
			$change->container()->name(),
		);
		$self->pop_dir();
	}
}

sub on_tag_rename {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());
	#$self->set_branch($revision, $change->container());

	my $old_tag_name = $change->src_container()->name();
	my $new_tag_name = $change->container()->name();

	# Find the change referenced by the old tag.
	my $old_tag_ref = $self->pipe_out_of_or_die("git rev-parse -- $old_tag_name");
	confess "unreferenced tag $old_tag_name" unless (
		defined $old_tag_ref and length $old_tag_ref
	);
	chomp $old_tag_ref;

	# Get the old revision, so we can reuse its message.
	$self->log("TAG) renaming from tag $old_tag_name");
	my $old_revision = delete $self->tags()->{$old_tag_name};

	# Create the new tag with the old reference.
	$self->git_env_setup($old_revision);
	$self->pipe_into_or_die(
		$old_revision->message(),
		"git tag -a -F - $new_tag_name $old_tag_ref"
	);

	# Delete the old tag.
	$self->git_env_setup($revision);
	$self->do_or_die("git", "tag", "-d", $old_tag_name);

	$self->pop_dir();

	$self->log("TAG) renaming to tag $new_tag_name");
	$self->tags()->{$new_tag_name} = $old_revision;
}

### Git helpers.

sub git_commit {
	my ($self, $revision) = @_;

	$self->push_dir($self->replay_base());

	# Every directory added is exploded into its constituent files.
	# Try to avoid "git-add --all".  It traverses the entire project
	# tree, which quickly gets expensive.

	if (scalar keys %{$self->directories_needing_add()}) {
		foreach my $dir (keys %{$self->directories_needing_add()}) {
			# TODO - Use File::Find when shell characters become an issue.
			foreach my $file (`find $dir -type f`) {
				chomp $file;
				$self->files_needing_add()->{$file} = 1;
			}
		}

		$self->directories_needing_add({});
		$self->needs_commit(1);
	}

	$self->git_env_setup($revision);

	my $needs_status = 1;
	if (scalar keys %{$self->files_needing_add()}) {
		# TODO - Break it up if the files list is too big.
		$self->do_or_die("git", "add", "-f", keys(%{$self->files_needing_add()}));
		$self->files_needing_add({});
		$self->needs_commit(1);
		$needs_status = 0;
	}

	unless ($self->needs_commit()) {
		$self->log("skipping git commit");
		$self->pop_dir();
		return;
	}

	my $git_commit_message_file = "/tmp/git-commit-$$.txt";

	open my $tmp, ">", $git_commit_message_file or confess $!;
	print $tmp $revision->message() or confess $!;
	close $tmp or confess $!;

	$self->git_env_setup($revision);

	# Some changes seem to alter no files.  We can detect whether a
	# commit is needed using git-status.  Otherwise, if we guess wrong,
	# git-commit will fail if there's nothing to commit.  We bother
	# checking git-commit because we do want to catch errors.

	# TODO - git-status is slow after a while.  Can we do something
	# smart to avoid it in all cases?
	if (
		!$needs_status or
		$self->do_sans_die("git status >/dev/null 2>/dev/null")
	) {
		$self->do_or_die(
			"git", "commit",
			($self->verbose() ? () : ("-q")),
			"-F", $git_commit_message_file
		);
	}

	unlink $git_commit_message_file;

	$self->needs_commit(0);
	$self->pop_dir();

	# Check for the need to GC.
	$self->revisions_until_gc( $self->revisions_until_gc() - 1 );
	if ($self->revisions_until_gc() < 1) {
		$self->do_git_gc();
		$self->revisions_until_gc( $self->revisions_between_gc() );
	}

	return;
}

sub do_git_gc {
	my $self = shift;
	$self->push_dir($self->replay_base());
	$self->do_or_die("git", "gc", ($self->verbose() ? () : ("--quiet")));
	$self->pop_dir();
}

### Helper methods.

#sub qualify_change_path {
#	my ($self, $change) = @_;
#	return $self->calculate_path($change->path());
#}

sub calculate_path {
	my ($self, $path) = @_;

	my $full_path = $self->replay_base() . "/" . $path;
	$full_path =~ s!//+!/!g;

	return $full_path;
}

sub git_env_setup {
	my ($self, $revision) = @_;

	croak "bad revision" unless defined $revision;

	$ENV{GIT_COMMITTER_DATE} = $ENV{GIT_AUTHOR_DATE} = $revision->time();

	my $rev_author = $revision->author();

	my ($author_name, $author_email);
	if ($self->authors()) {
		my $git_author = $self->authors()->{$rev_author};
		unless (defined $git_author and length $git_author) {
			confess(
				"svn author '$rev_author' doesn't seem to be in your authors file"
			);
		}
		$author_name  = $git_author->name();
		$author_email = $git_author->email();
	}
	else {
		$author_name  = $rev_author;
		$author_email = "$rev_author\@example.com";
	}

	# TODO - Use the svn repository's GUID as the email host.
	$ENV{GIT_COMMITTER_NAME}  = $ENV{GIT_AUTHOR_NAME}  = $author_name;
	$ENV{GIT_COMMITTER_EMAIL} = $ENV{GIT_AUTHOR_EMAIL} = $author_email;
}

sub ensure_parent_dir_exists {
	my ($self, $path) = @_;
	$path =~ s!/[^/]+/?$!!;
	return unless length $path and $path ne "/";
	return if -e $path;
	$self->log("mkpath $path");
	mkpath($path) or confess "mkpath failed: $!";
}

sub set_branch {
	my ($self, $revision, $container) = @_;

	# Assumes that the cwd is the replay repository.

	# What we do depends on the changed entity type.
	my $type = $container->type();
	my $name = $container->name();

	if ($type eq "branch") {

		# Subversion trunk equates to git master.
		$name = "master" if $name eq "trunk";

		if ($name eq $self->current_branch()) {
			$self->log("GIT) already on branch $name");
			return;
		}

		$self->git_commit($revision);

		$self->do_sans_die("git", "checkout", $name);
		$self->current_branch($name);

		# TODO - We also need to prune the paths within the entity.
		# Branches don't belong in /branch, for example.

		return;
	}

	confess "set_branch() inappropriately called for a $type $name";

	# Map the change's container to an appropriate branch.
	$self->log($container->debug("!!! branch %s"));
}

# Already in the destination branch.
sub do_directory_copy {
	my ($self, $src_branch_name, $change, $branch_rel_path) = @_;

	confess "cp to $branch_rel_path failed: path exists" if -e $branch_rel_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		$src_branch_name, $change
	);

	# Directory copy sources are tarballs.
	$copy_depot_path .= ".tar.gz";

	unless (-e $copy_depot_path) {
		confess "cp source $copy_depot_path ($copy_depot_descriptor) doesn't exist";
	}

	$self->do_mkdir($branch_rel_path);
	$self->push_dir($branch_rel_path);
	$self->do_or_die("tar", "xzf", $copy_depot_path);
	$self->pop_dir();
}

sub do_file_copy {
	my ($self, $src_branch_name, $change, $revision) = @_;

	my $branch_rel_path = $change->rel_path();

	confess "cp to $branch_rel_path failed: path exists" if -e $branch_rel_path;

	my ($copy_depot_descriptor, $copy_depot_path) = $self->get_copy_depot_info(
		$src_branch_name, $change
	);

	unless (-e $copy_depot_path) {
		confess "cp source $copy_depot_path ($copy_depot_descriptor) doesn't exist";
	}

	# Weirdly, the copy source may not be authoritative.
	if (defined $change->content()) {
		$self->write_change_data($change, $branch_rel_path);
		return;
	}

	# If content isn't provided, however, copy the file from the depot.
	$self->copy_file_or_die($copy_depot_path, $branch_rel_path);
}

1;
