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
use SVN::Dump::Change::Rename;

has id      => ( is => 'ro', isa => 'Int', required => 1 );
has author  => ( is => 'ro', isa => 'Str', required => 1 );
has time    => ( is => 'ro', isa => 'Str', required => 1 );
has message => ( is => 'ro', isa => 'Str', required => 1 );
has is_open => ( is => 'rw', isa => 'Bool', default => 1 );

has changes => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Dump::Change]',
	default => sub { [] },
);

sub push_change {
	my ($self, $change) = @_;

	# Convert Cpdir/Rmdir sequences into Renames.
	if (
		@{$self->changes()} and
		$change->isa("SVN::Dump::Change::Rmdir") and
		$self->changes()->[-1]->isa("SVN::Dump::Change::Cpdir") and
		$self->changes()->[-1]->src_path() eq $change->path()
	) {
		# TODO - Reblessing would be easier. Is it an option?
		my $previous_change = pop @{$self->changes()};

		# Renaming cannot change the entity type.  One may not rename a
		# branch into a tag, a file into a directory, etc.
		$previous_change->container()->type(
			$previous_change->src_container()->type()
		);

		$change = SVN::Dump::Change::Rename->new(
			path          => $previous_change->path(),
			container     => $previous_change->container(),
			src_rev       => $previous_change->src_rev(),
			src_path      => $previous_change->src_path(),
			src_container => $previous_change->src_container(),
		);
	}
	
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
