package SVN::Analysis::Change::Copy;

use Moose;
extends 'SVN::Analysis::Change::Add';

has src_path      => ( is => 'ro', isa => 'Str', default  => "" );
has src_revision  => ( is => 'ro', isa => 'Str', default  => "" );

sub is_copy   { 1 }

1;
