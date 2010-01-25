package SVN::Dump::Change::Edit;

use Moose;
extends 'SVN::Dump::Change';

has content => ( is => 'ro', isa => 'Str', required => 1 );

has '+operation' => ( default => 'file_change' );

1;
