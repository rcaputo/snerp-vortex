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

use Moose;
extends 'SVN::Dump::Replayer';

has git_replay_base => ( is => 'ro', isa => 'Str', required => 1 );
has authors_file    => ( is => 'ro', isa => 'Str' );
has authors => (
	is => 'rw',
	isa => 'HashRef[SVN::Dump::Replayer::Git::Author]',
	default => sub { {} }
);

###

after on_revision_done => sub {
	my $self = shift;
	my $final_revision = $self->arborist()->pending_revision();
	#use YAML::Syck; print YAML::Syck::Dump($final_revision);
};

after on_walk_begin => sub {
  my $self = shift;

	# Set up authors mapping.
  if (defined $self->authors_file()) {
    open my $fh, "<", $self->authors_file() or die $!;
    while (<$fh>) {
      my ($nick, $name, $email) = (/(\S+)\s*=\s*(\S[^<]*?)\s*<(\S+?)>/);
      $self->authors()->{$nick} = SVN::Dump::Replayer::Git::Author->new(
        name  => $name,
        email => $email,
      );
    }
  }

	$self->do_rmdir($self->git_replay_base()) if -e $self->git_replay_base();
	$self->do_mkdir($self->git_replay_base());

	$self->push_dir($self->git_replay_base());
	$self->do_or_die("git", "init");
	$self->pop_dir();
};

after on_walk_done => sub {
	my $self = shift;
	die;
	# TODO - Anything?
	undef;
};

after on_branch_directory_creation => sub {
	my ($self, $change) = @_;
	$self->do_mkdir($self->qualify_git_path($change));
};

after on_branch_directory_copy => sub {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_git_path($change));
};

after on_directory_copy => sub {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_git_path($change));
};

after on_directory_creation => sub {
	my ($self, $change) = @_;
	$self->do_mkdir($self->qualify_git_path($change));
};

after on_directory_deletion => sub {
	my ($self, $change) = @_;
	$self->do_rmdir_safely($self->qualify_git_path($change));
};

after on_file_change => sub {
	my ($self, $change) = @_;
	$self->rewrite_file($change, $self->qualify_git_path($change));
};

after on_file_copy => sub {
	my ($self, $change) = @_;
	$self->do_file_copy($change, $self->qualify_git_path($change));
};

after on_file_creation => sub {
	my ($self, $change) = @_;
	$self->write_new_file($change, $self->qualify_git_path($change));
};

after on_file_deletion => sub {
	my ($self, $change) = @_;
	$self->do_file_deletion($self->qualify_git_path($change));
};

after on_tag_directory_copy => sub {
	my ($self, $change) = @_;
	$self->do_directory_copy($change, $self->qualify_git_path($change));
};

### Helper methods.

sub qualify_git_path {
	my ($self, $change) = @_;
	return $self->calculate_git_path($change->path());
}

sub calculate_git_path {
	my ($self, $path) = @_;

	my $full_path = $self->git_replay_base() . "/" . $path;
	$full_path =~ s!//+!/!g;

	return $full_path;
}

1;
