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

###

after on_revision_done => sub {
	my ($self, $revision_id) = @_;
	my $final_revision = $self->arborist()->pending_revision();
	$self->git_commit($final_revision);
};

after on_walk_begin => sub {
	my $self = shift;

	# Set up authors mapping.
	if (defined $self->authors_file()) {
		# Initialize it.  Probably can use Moose to tell us it's been set.
		$self->authors({});

		open my $fh, "<", $self->authors_file() or die $!;
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
	$self->do_mkdir($self->qualify_change_path($change));
	# Git doesn't track directories, so nothing to add.
}

sub on_branch_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
	$self->directories_needing_add()->{$change->path()} = 1;
}

sub on_directory_copy {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
	$self->directories_needing_add()->{$change->path()} = 1;
}

sub on_directory_creation {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
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

	die "can't remove nonexistent directory ", $change->path() unless (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$change->path(),
	);

	$self->ensure_parent_dir_exists($change->path());
	$self->pop_dir();

	# Second, try a plain filesystem remove in case the file hasn't yet
	# been staged.  Since git-rm may have removed any number of parent
	# directories for $rel_path, we only try to rmtree() if it still
	# exists.
	my $full_path = $self->qualify_change_path($change);
	$self->do_rmdir($full_path) if -e $full_path;
	$self->ensure_parent_dir_exists($full_path);

	delete $self->directories_needing_add()->{$change->path()};
	$self->needs_commit(1);
}

sub on_branch_directory_deletion {
	my ($self, $change, $revision) = @_;

	# TODO - Branches are pretty much mapped to directories for now.
	# This is a copy/paste of on_directory_deletion().

	$self->push_dir($self->replay_base());

	die "can't remove nonexistent branch directory ", $change->path() unless (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$change->path(),
	);
	$self->pop_dir();

	# Second, try a plain filesystem remove in case the file hasn't yet
	# been staged.  Since git-rm may have removed any number of parent
	# directories for $rel_path, we only try to rmtree() if it still
	# exists.
	my $full_path = $self->qualify_change_path($change);
	$self->do_rmdir($full_path) if -e $full_path;

	$self->ensure_parent_dir_exists($full_path);

	delete $self->directories_needing_add()->{$change->path()};
	$self->needs_commit(1);
}

sub on_file_change {
	my ($self, $change, $revision) = @_;
	if ($self->rewrite_file($change, $self->qualify_change_path($change))) {
		$self->files_needing_add()->{$change->path()} = 1;
	}
}

sub on_file_copy {
	my ($self, $change, $revision) = @_;
	$self->do_file_copy($change, $self->qualify_change_path($change));
	$self->files_needing_add()->{$change->path()} = 1;
}

sub on_file_creation {
	my ($self, $change, $revision) = @_;
	$self->write_new_file($change, $self->qualify_change_path($change));
	$self->files_needing_add()->{$change->path()} = 1;
}

sub on_file_deletion {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());

	die "can't remove nonexistent file ", $change->path() unless (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$change->path(),
	);

	$self->ensure_parent_dir_exists($change->path());
	$self->pop_dir();

	delete $self->files_needing_add()->{$change->path()};
	$self->needs_commit(1);
}

sub on_tag_directory_copy {
	my ($self, $change, $revision) = @_;

	$self->git_commit($revision);

	my $tag_name = $change->container()->name();
	$self->push_dir($self->replay_base());

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

	die "target of file rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or
	die(
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

	die "target of rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or
	die(
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

	die "target of directory rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or
	die(
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
	$self->push_dir($self->replay_base());

	die "target of branch rename (", $change->path(), ") already exists" if (
		-e $change->path()
	);

	$self->git_env_setup($revision);

	$self->do_sans_die("git", "mv", $change->src_path(), $change->path()) or
	rename($change->src_path(), $change->path()) or
	die(
		"branch rename from ", $change->src_path(),
		" to ", $change->path(),
		"failed: $!"
	);

	$self->ensure_parent_dir_exists($change->src_path());
	$self->pop_dir();
	$self->needs_commit(1);

	# TODO - Try this when we have actual git branching.  Meanwhile, use
	# the above git-mv code.
	#
	#$self->push_dir($self->replay_base());
	#$self->do_or_die(
	#	"git", "branch", "-m",
	#	$change->src_container()->name(),
	#	$change->container()->name(),
	#);
	#$self->pop_dir();
}

sub on_tag_rename {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());

	my $old_tag_name = $change->src_container()->name();
	my $new_tag_name = $change->container()->name();

	# Find the change referenced by the old tag.
	my $old_tag_ref = $self->pipe_out_of_or_die("git rev-parse -- $old_tag_name");
	die "unreferenced tag $old_tag_name" unless (
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

	open my $tmp, ">", $git_commit_message_file or die $!;
	print $tmp $revision->message() or die $!;
	close $tmp or die $!;

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

sub git_env_setup {
	my ($self, $revision) = @_;

	croak "bad revision" unless defined $revision;

	$ENV{GIT_COMMITTER_DATE} = $ENV{GIT_AUTHOR_DATE} = $revision->time();

	my $rev_author = $revision->author();

	my ($author_name, $author_email);
	if ($self->authors()) {
		my $git_author = $self->authors()->{$rev_author};
		unless (defined $git_author and length $git_author) {
			die "svn author '$rev_author' doesn't seem to be in your authors file";
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
	mkpath($path) or die "mkpath failed: $!";
}

1;
