package SVN::Dump::Snapshot::File;

use Moose;
extends 'SVN::Dump::Snapshot::Node';

has kind    => ( is => 'ro', isa => 'Str', default => 'file' );
has content => ( is => 'ro', isa => 'Str', required => 1 );
1;
