package SVN::Analysis::Change;

use Moose;

has revision  => ( is => 'rw', isa => 'Int', required => 1 );

1;
