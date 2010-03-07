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

sub is_from_container {
	my $self = shift;
	return 1 if $self->src_path() eq $self->src_container()->path();
	return;
}

has rel_src_path => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	default => sub {
		my $self = shift;

		my $path = $self->src_path();
		my $container_path = $self->src_container()->path();
		my $base_path = $self->src_container()->base_path();

		if (length $container_path) {
			die "path $path is not within container $container_path" unless (
				$path =~ s!^\Q$container_path\E(/|$)!./$base_path$1!
			);
		}
		else {
			substr($path, 0, 0) = "./$base_path/";
		}

		$path =~ tr[/][/]s;
		$path =~ s!/+$!!;

		return $path;
	},
);

1;
