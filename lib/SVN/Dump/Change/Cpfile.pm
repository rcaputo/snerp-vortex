package SVN::Dump::Change::Cpfile;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+operation'  => ( default => 'file_copy' );
has content       => ( is => 'ro', isa => 'Maybe[Str]' );

1;
