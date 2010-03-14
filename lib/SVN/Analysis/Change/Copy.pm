package SVN::Analysis::Change::Copy;

use Moose;
extends 'SVN::Analysis::Change';

has src_path      => ( is => 'ro', isa => 'Str', default  => "" );
has src_revision  => ( is => 'ro', isa => 'Str', default  => "" );

sub is_add    { 0 }
sub is_copy   { 1 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 1 }

1;
