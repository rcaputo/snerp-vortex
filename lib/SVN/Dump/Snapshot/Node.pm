package SVN::Dump::Snapshot::Node;

use Moose;

has revision => ( is => 'rw', isa => 'Int', required => 1 );

1;
