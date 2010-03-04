package SVN::Dump::Change;

use Moose;

has path      => ( is => 'ro', isa => 'Str', required => 1 );
has operation => ( is => 'ro', isa => 'Str' );

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

sub debug {
	my ($self, $template) = @_;
	sprintf(
		$template,
		$self->operation() . " " . $self->path() . " " .
		$self->container()->debug("container(%s)")
	);
}

has rel_path => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	default => sub {
		my $self = shift;
		my $path = $self->path();

		return $path if $self->is_container();

		my $container_path = $self->container()->path();

		if (length $container_path) {
			die "$path is not within $container_path" unless (
				$path =~ s/^\Q$container_path\E(\/|$)/trunk$1/
			);
		}

		return $path;
	},
);

1;
