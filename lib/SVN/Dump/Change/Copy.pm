package SVN::Dump::Change::Copy;

use Moose;
extends 'SVN::Dump::Change';

has src_rev     => ( is => 'ro', isa => 'Int', required => 1 );
has src_path    => ( is => 'ro', isa => 'Str', required => 1 );

has src_container => (
	is => 'ro',
	isa => 'SVN::Dump::Entity',
	required => 1
);

sub from_container {
	my $self = shift;
	return 1 if $self->src_path() eq $self->src_container()->path();
	return;
}

1;
