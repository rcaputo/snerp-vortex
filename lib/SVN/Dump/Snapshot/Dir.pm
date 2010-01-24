package SVN::Dump::Snapshot::Dir;

use Moose;
extends 'SVN::Dump::Snapshot::Node';

has contents => (
	is => 'rw',
	isa => 'HashRef[SVN::Dump::Snapshot::Node]',
	default => sub { {} },
);

has kind => ( is => 'ro', isa => 'Str', default => 'dir' );

1;
