package SVN::Dump::Snapshot;

use Moose;
use SVN::Dump::Snapshot::Dir;
use SVN::Dump::Snapshot::File;

has revision  => ( is => 'rw', isa => 'Int', required => 1 );
has author    => ( is => 'rw', isa => 'Str', required => 1 );
has time      => ( is => 'rw', isa => 'Str', required => 1 );
has message   => ( is => 'rw', isa => 'Str', required => 1 );
has root      => (
	is  => 'rw',
	isa => 'SVN::Dump::Snapshot::Node',
);

1;
