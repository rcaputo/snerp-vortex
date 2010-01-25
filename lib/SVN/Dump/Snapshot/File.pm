package SVN::Dump::Snapshot::File;

use Moose;
extends 'SVN::Dump::Snapshot::Node';

has kind    => ( is => 'ro', isa => 'Str', default => 'file' );

1;
