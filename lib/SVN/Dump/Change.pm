package SVN::Dump::Change;

use Moose;

has path      => ( is => 'ro', isa => 'Str', required => 1 );
has callback  => ( is => 'ro', isa => 'Str' );

has container => (
	is        => 'ro',
	isa       => 'SVN::Dump::Entity',
	required  => 1
);

sub is_container {
	my $self = shift;
	return 1 if $self->path() eq $self->container()->path();
	return;
}

1;
