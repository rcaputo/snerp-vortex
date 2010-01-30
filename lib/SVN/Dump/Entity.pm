package SVN::Dump::Entity;

# Represent a SVN entity: branch or tag.

use Moose;
use Carp qw(cluck carp);

has first_revision_id => ( is => 'rw', isa => 'Int', required => 1 );
has last_revision_id  => ( is => 'rw', isa => 'Int', required => 1 );
has type              => ( is => 'rw', isa => 'Str', required => 1 );
has name              => ( is => 'rw', isa => 'Str', required => 1 );
has exists            => ( is => 'rw', isa => 'Bool', required => 1 );
has path              => ( is => 'ro', isa => 'Str', required => 1 );
has modified          => ( is => 'rw', isa => 'Bool', required => 1 );

# Every copy that's sourced directly from this entity.
has descendents => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Entity]',
	default => sub { [] },
);

# Tags that are changed after the fact are really branches.
# Likewise, branches that haven't been changed may as well be tags.

sub fix_type {
	my $self = shift;

	my $type = $self->type();

	# I am modified if any entity that copies from me is modified.  SCMs
	# that care need to know.
	my $modified = $self->modified();
	unless ($modified) {
		foreach (@{$self->descendents()}) {
			if ($_->modified()) {
				$self->modified($modified = 1);
				last;
			}
		}
	}

	# TODO - Type fixing must consider renames.  Scenario:
	#
	# svn cp /trunk /tag/foo
	# svn cp /tag/foo /branch/bar
	# svn commit changes in /branch/bar
	#
	# Git tags can't be modified like that.  They're meant to be leaf
	# nodes on the revision tree.  If a tag is a source of files that
	# are later copied, then it must be downgraded to a branch.
	#
	# TODO - Can we defer the behavior to SVN::Dump::Replayer::Git?
	# Other SCM systems may not have Git's limitation.  For example,
	# SVN::Dump::Replayer::Subversion would definitely be allowed.

	if ($type eq "tag") {
		$self->type("branch") if $modified;
		return;
	}

	if ($type eq "branch") {
		$self->type("tag") unless $modified;
		return;
	}

	return if $type eq "meta";

	confess "entity has unexpected type: " . $self->type();
}

sub debug {
	my ($self, $template) = @_;
	sprintf $template, $self->type() . " " . $self->name();
}

1;
