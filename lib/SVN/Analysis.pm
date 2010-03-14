package SVN::Analysis;

use Moose;
use Carp qw(confess);

use XML::LibXML;

use SVN::Analysis::Change::Add;
use SVN::Analysis::Change::Copy;
use SVN::Analysis::Change::Delete;
use SVN::Analysis::Change::Touch;

has dir => (
	is => 'rw',
	isa => 'HashRef[ArrayRef[SVN::Analysis::Change]]',
	default => sub { { } },
);

### External entry points.

sub consider_add {
	my ($self, $revision, $path, $kind) = @_;

	# Added a file.  Touch all the containers that hold it.
	return $self->touch_file($revision, $path) if $kind ne "dir";

	# Adding a directory.  It shall not previously exist.
	confess "adding previously existing path $path at r$revision" if (
		$self->path_exists_now($path)
	);

	# Add unconditionally.
	push @{$self->dir()->{$path}}, SVN::Analysis::Change::Add->new(
		revision => $revision,
	);
	return;
}

sub consider_change {
	my ($self, $revision, $path, $kind) = @_;
	return $self->touch_file($revision, $path) if $kind ne "dir";
	return $self->touch_directory($revision, $path);
}

sub consider_copy {
	my ($self, $dst_revision, $dst_path, $kind, $src_revision, $src_path) = @_;

	# Copied a file.  Touch its containers.
	return $self->touch_file($dst_revision, $dst_path) if $kind ne "dir";

	# Copy the source path and all the entire tree below.
	foreach my $path_to_copy (
		$self->get_tree_paths_then($src_revision, $src_path)
	) {
		my $relocated_path = $path_to_copy;
		$relocated_path =~ s/^\Q$src_path\E(\/|$)/$dst_path$1/ or confess(
			"can't relocate $path_to_copy from $src_path to $dst_path"
		);

		# It would suck if the relocated path existed.
		confess "relocated path $relocated_path exists at r$dst_revision" if (
			$self->path_exists_now($relocated_path)
		);

		push(
			@{$self->dir()->{$relocated_path}},
			SVN::Analysis::Change::Copy->new(
				revision      => $dst_revision,
				src_path      => $path_to_copy,
				src_revision  => $src_revision,
			)
		);

		# Touch the relocated path.
		$self->touch_directory($dst_revision, $relocated_path);
	}

	return;
}

sub consider_delete {
	my ($self, $revision, $path) = @_;

	# Touch all the containers of the thing about to be deleted.
	# Cheat by treating the path as a file regardless of its real kind.
	$self->touch_file($revision, $path) unless $self->path_exists_now($path);

	foreach my $path_to_delete ($self->get_tree_paths_now($path)) {
		my $path_rec = $self->dir()->{$path_to_delete};

		# Double deletion is bad.
		confess "deleting nonexistent $path_to_delete at r$revision" unless (
			$self->path_exists_now($path_to_delete)
		);

		# This delete operation indicates the end of the path's lifetime.
		# A previous touch operation is redundant and can be removed.
		pop @$path_rec if $path_rec->[-1]->is_touch();

		push @$path_rec, SVN::Analysis::Change::Delete->new(
			revision => $revision,
		);
	}

	return;
}

sub analyze {
	my $self = shift;
	return;
}

sub as_xml_string {
	my $self = shift;

	my $document = XML::LibXML::Document->new("1.0", "UTF-8");

	my $analysis = $document->createElement("analysis");
	$document->setDocumentElement($analysis);

	foreach my $path (sort keys %{$self->dir()}) {

		my $directory = $document->createElement("directory");
		$directory->setAttribute(path => $path);

		$analysis->appendChild($directory);

		foreach my $change (@{$self->dir()->{$path}}) {
			$directory->appendChild($change->as_xml_element($document));
		}
	}

	return $document->toString();
}

sub init_from_xml_string {
	my ($self, $xml) = @_;

	my $parser = XML::LibXML->new();
	my $document = $parser->parse_string($xml);

	foreach my $directory ($document->findnodes("/analysis/directory")) {
		$self->dir()->{$directory->getAttribute("path")} = [
			map { SVN::Analysis::Change->new_from_xml_element($_) }
			$directory->getChildrenByLocalName("change")
		];
	}

	return;
}

### Internal helpers.

sub path_exists_now {
	my ($self, $path) = @_;
	return(
		exists($self->dir()->{$path}) &&
		$self->dir()->{$path}->[-1]->exists()
	);
}

sub path_exists_then {
	my ($self, $revision, $path) = @_;

	# Path doesn't exist.
	return unless exists $self->dir()->{$path};

	my $changes = $self->dir()->{$path};
	my $i = @$changes;

	while ($i--) {
		next if $changes->[$i]->revision() > $revision;
		return $changes->[$i]->exists();
	}

	# Doesn't exist.
	return;
}

sub touch_directory {
	my ($self, $revision, $path) = @_;

	foreach my $container_path ($self->get_container_paths($path)) {
		my $path_rec = $self->dir()->{$container_path};

		my $last_change = $path_rec->[-1];

		# A touch is redundant if it's in the same reivison as another
		# operation that indicates the path exists.
		next if $last_change->revision() == $revision and $last_change->exists();

		# A touch is redundant if it follows another touch.  We only need
		# to know the last touch revision, which is a hint that it may be
		# safe to garbage collect the path information.
		if ($last_change->is_touch()) {
			$last_change->revision($revision);
			next;
		}

		# Record a distinct touch.
		push @$path_rec, SVN::Analysis::Change::Touch->new(
			revision => $revision,
		);
	}

	return;
}

sub touch_file {
	my ($self, $revision, $path) = @_;
	$path =~ s!/*[^/]+/*$!!;
	$self->touch_directory($revision, $path);
	return;
}

sub get_tree_paths_now {
	my ($self, $path) = @_;
	return(
		sort { (length($a) <=> length($b)) || ($a cmp $b) }
		grep { $self->path_exists_now($_) }
		grep /^\Q$path\E(\/|$)/,
		keys %{$self->dir()}
	);
}

sub get_tree_paths_then {
	my ($self, $revision, $path) = @_;
	return(
		sort { (length($a) <=> length($b)) || ($a cmp $b) }
		grep { $self->path_exists_then($revision, $_) }
		grep /^\Q$path\E(\/|$)/,
		keys %{$self->dir()}
	);
}

sub get_container_paths {
	my ($self, $path) = @_;

	my @paths;

	my $shrinking_path = $path;
	while (length $shrinking_path) {
		confess "$shrinking_path not a container of $path" unless (
			$self->path_exists_now($shrinking_path)
		);

		push @paths, $shrinking_path;
		$shrinking_path =~ s!/*[^/]+/*$!!;
	}

	# The empty root directory also counts.
	push @paths, "";

	return @paths;
}

1;
