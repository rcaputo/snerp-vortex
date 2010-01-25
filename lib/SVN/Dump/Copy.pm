package SVN::Dump::Copy;

use Moose;

has src_revision  => ( is => 'ro', isa => 'Int', required => 1 );
has src_path      => ( is => 'ro', isa => 'Str', required => 1 );

1;
