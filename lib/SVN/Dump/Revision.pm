package SVN::Dump::Revision;

# Encapsulate a revision.

use Moose;

use SVN::Dump::Change::Mkfile;
use SVN::Dump::Change::Mkdir;
use SVN::Dump::Change::Edit;
use SVN::Dump::Change::Rmdir;
use SVN::Dump::Change::Rmfile;
use SVN::Dump::Change::Cpfile;
use SVN::Dump::Change::Cpdir;

has id      => ( is => 'ro', isa => 'Int', required => 1 );
has author  => ( is => 'ro', isa => 'Str', required => 1 );
has time    => ( is => 'ro', isa => 'Str', required => 1 );
has message => ( is => 'ro', isa => 'Str', required => 1 );

has changes => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Change]',
	default => sub { [] },
);

sub push_change {
	my ($self, $change) = @_;
	
	push @{$self->changes()}, $change;
}

# Optimize the revision.
# For example, copy-and-delete-source is really a move or rename.

sub optimize {
	my $self = shift;

	my $changes = $self->changes();

	# No optimizations possible when there's only a single change.
	return if @$changes < 2;

	# TODO - Any optimizations possible?

	return;
}

1;
