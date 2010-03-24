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

# TODO - Optimize runtime copy sources by managing their reference
# counts.  Replayers can delete copy depot files when they stop being
# useful.  Likewise, copy_sources() can shrink, with memory and
# lookups reducing as well.

#{
#	package SVN::Analysis::CopySource;
#	use Moose;
#	has kind    => ( is => 'rw', isa => 'Str', required => 1 );
#	has refcnt  => ( is => 'rw', isa => 'Int', required => 1 );
#
#	sub refcnt_inc {
#		my $self = shift;
#		return $self->refcnt( $self->refcnt() + 1 );
#	}
#
#	sub refcnt_dec {
#		my $self = shift;
#		return $self->refcnt( $self->refcnt() - 1 );
#	}
#}

has copy_sources => (
	is      => 'rw',
	isa     => 'HashRef[HashRef[Str]]',
	default => sub { { } },
);

### External entry points.

sub consider_add {
	my ($self, $revision, $path, $kind) = @_;

	# Touch the parent directory of the thing being added.
	$self->touch_parent_directory($revision, $path);

	# If this is a file, we're done.
	return if $kind ne "dir";

	# Adding a directory.  It shall not previously exist.
	confess "adding previously existing path $path at r$revision" if (
		$self->path_exists_now($path)
	);

	# Add unconditionally.
	push @{$self->dir()->{$path}}, SVN::Analysis::Change::Add->new(
		revision      => $revision,
		path          => $path,
		path_lop      => "",
		path_prepend  => "",
	);

	return;
}

sub consider_change {
	my ($self, $revision, $path, $kind) = @_;
	return $self->touch_parent_directory($revision, $path) if $kind ne "dir";
	return $self->touch_directory($revision, $path);
}

sub consider_copy {
	my ($self, $dst_revision, $dst_path, $kind, $src_revision, $src_path) = @_;

	# Remember the copy source.
	$self->copy_sources()->{$src_revision}{$src_path} = $kind;

	# Touch the directory where the copy is landing.
	$self->touch_parent_directory($dst_revision, $dst_path);

	# If this is a file, we're done.
	return if $kind ne "dir";

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
				path          => $relocated_path,
				path_lop      => "",
				path_prepend  => "",
			)
		);
	}

	return;
}

sub consider_delete {
	my ($self, $revision, $path) = @_;

	# Touch the parent directory and all its ancestors back to the root.
	$self->touch_parent_directory($revision, $path);

	# If the path doesn't exist, then we just deleted a file.
	return unless exists $self->dir()->{$path};

	# Otherwise flag the tree at the deletion point.
	foreach my $path_to_delete ($self->get_tree_paths_now($path)) {
		my $path_rec = $self->dir()->{$path_to_delete};

		# Double deletion is bad.
		confess "deleting nonexistent $path_to_delete at r$revision" unless (
			$self->path_exists_now($path_to_delete)
		);

		push @$path_rec, SVN::Analysis::Change::Delete->new(
			revision      => $revision,
			path          => $path_to_delete,
			path_lop      => "",
			path_prepend  => "",
		);
	}

	return;
}

sub get_entity_hint {
	my ($self, $path) = @_;

	$path = "" unless defined $path;

	# Project root.
	#return("branch", "proj-root", "", "") unless defined $path and length $path;

	# Special top-level paths.  Nothing to do.
	#	return("branch", "proj-root", "", "") if (
	#		$path =~ m!^(trunk|tags?|branch(?:es)?)$!
	#	);

	# Trunk.
	return("branch", "trunk", $1, "") if (
		$path =~ m!^(trunk)(?:/|$)!
	);

	# Branches and tags.
	return("branch", "branch-$2", $1, "") if (
		$path =~ m!^(branch(?:es)?/([^/]+))(?:/|$)!
	);
	return("tag", "tag-$2", $1, "") if (
		$path =~ m!^(tags?/([^/]+))(?:/|$)!
	);

	# Special project paths.  Nothing to do.
	#	return("branch", "proj-root", "", "") if (
	#		$path =~ m!^[^/]+/(trunk|tags?|branch(?:es)?)$!
	#	);

	# Project directories.
	return("branch", "proj-$2", $1, "") if (
		$path =~ m!^(([^/]+)/trunk)(?:/|$)!
	);
	return("branch", "proj-$2-branch-$3", $1, "") if (
		$path =~ m!^(([^/]+)/branch(?:es)?/([^/]+))(?:/|$)!
	);
	return("tag", "proj-$2-tag-$3", "$1", "") if (
		$path =~ m!^(([^/]+)/tags?/([^/]+))(?:/|$)!
	);

	# Catch-all.  Must go at the end.
	return("branch", "proj-root", "", "");
}

sub analyze {
	my $self = shift;

	my $dir = $self->dir();

	# First pass fixes the lop and prepend based on entity hints.

	PATH: while (my ($path, $changes) = each %$dir) {
		my ($entity_type, $entity_name, $path_lop, $path_prepend) = (
			$self->get_entity_hint($path)
		);

		# Walk the changes backwards to find modified entities.

		my $entity_was_touched = 0;
		CHANGE: foreach my $change (reverse @$changes) {
			$change->path_lop($path_lop);
			$change->path_prepend($path_prepend);

			# Track whether an entity was modified.
			$entity_was_touched++ if $change->is_touch();

			if ($change->is_entity()) {
				# Reify contents of entities that are touched.
				$change->entity_type($entity_was_touched ? "branch" : $entity_type);
				$change->entity_name($entity_name);
			}
			else {
				$change->entity_type("");
				$change->entity_name("");
			}

			# Adds and deletions reset the entity's state.
			$entity_was_touched = 0 if $change->is_add() or $change->is_delete();
		}
	}
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

	foreach my $revision (sort { $a <=> $b } keys %{$self->copy_sources()}) {
		foreach my $path (sort keys %{$self->copy_sources()->{$revision}}) {
			my $copy_source = $document->createElement("copy_source");
			$copy_source->setAttribute(revision => $revision);
			$copy_source->setAttribute(path => $path);
			$copy_source->setAttribute(
				kind => $self->copy_sources()->{$revision}{$path}
			);

			$analysis->appendChild($copy_source);
		}
	}

	return $document->toString();
}

# Return the IDs of significant revisions, in chronological order.
sub significant_revisions {
	my $self = shift;
	return(
		sort { $a <=> $b }
		keys %{
			{
				map { ($_->revision(), 1) }
				grep { $_->is_add() }
				map { @$_ } values %{$self->dir()}
			}
		}
	);
}

sub as_tree_then {
	my ($self, $revision) = @_;

	my $root_name = "(repository)";
	my $root_node = $self->path_as_then($revision, "");

	my $tree = {
		node      => $root_node,
		name      => $root_name,
		children  => [ ],
	};

	foreach my $path ($self->get_tree_paths_then($revision, "")) {
		my $iter = $tree;

		my $path_then = $self->path_as_then($revision, $path);
		die "wtf" unless $path_then->exists();

		foreach my $segment (split m!/!, $path) {
			my @candidates = (
				grep { $_->{name} eq $segment }
				@{$iter->{children}}
			);

			die "$segment = @candidates" if @candidates > 1;

			unless (@candidates) {
				my $new = {
					node      => $path_then,
					name      => $segment,
					children  => [ ],
				};

				push @{$iter->{children}}, $new;

				$iter = $new;
				next;
			}

			$iter = $candidates[0];
		}
	}

	# Traverse the tree, sorting the children by name.
	my @pending = ($tree);
	while (@pending) {
		my $iter = shift @pending;
		push(
			@pending, @{
				$iter->{children} = [
					sort { $a->{name} cmp $b->{name} }
					@{$iter->{children}}
				]
			}
		);
	}

	return $tree;
}

sub init_from_xml_file {
	my ($self, $filename) = @_;
	$self->init_from_xml_document(XML::LibXML->load_xml(location => $filename));
	return;
}

sub init_from_xml_string {
	my ($self, $xml) = @_;
	$self->init_from_xml_document(XML::LibXML->load_xml(string => $xml));
	return;
}

sub init_from_xml_document {
	my ($self, $document) = @_;

	my $dir = $self->dir();
	foreach my $directory ($document->findnodes("/analysis/directory")) {
		$dir->{$directory->getAttribute("path")} = [
			map { SVN::Analysis::Change->new_from_xml_element($_) }
			$directory->getChildrenByLocalName("change")
		];
	}

	my $sources = $self->copy_sources();
	foreach my $cs ($document->findnodes("/analysis/copy_source")) {
		$sources->{$cs->getAttribute("revision")}{$cs->getAttribute("path")} = (
			$cs->getAttribute("kind")
		);
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

	my $change = $self->get_path_change_then($revision, $path);
	return unless defined $change;
	return $change->exists();
}

sub path_as_then {
	my ($self, $revision, $path) = @_;

	# Path doesn't exist.
	return unless exists $self->dir()->{$path};

	my $changes = $self->dir()->{$path};
	my $i = @$changes;

	while ($i--) {
		next if $changes->[$i]->revision() > $revision;
		return unless $changes->[$i]->exists();
		return $changes->[$i];
	}

	# Doesn't exist.
	return;
}

sub touch_directory {
	my ($self, $revision, $path) = @_;

	foreach my $container_path ($self->get_container_paths($path)) {
		my $path_rec = $self->dir()->{$container_path};

		my $last_change = $path_rec->[-1];

		# A touch is redundant if it follows another touch.  We only need
		# to know the most recent touched revision.
		if ($last_change->is_touch()) {
			$last_change->revision($revision);
			next;
		}

		# Record a distinct touch.
		push @$path_rec, SVN::Analysis::Change::Touch->new(
			revision      => $revision,
			path          => $container_path,
			path_lop      => "",
			path_prepend  => "",
		);
	}

	return;
}

sub touch_parent_directory {
	my ($self, $revision, $path) = @_;
	return unless length $path;
	$path =~ s!/*[^/]*/*$!!;
	$self->touch_directory($revision, $path);
	return;
}

sub get_tree_paths_now {
	my ($self, $path) = @_;
	return(
		sort { (length($a) <=> length($b)) || ($a cmp $b) }
		grep { $self->path_exists_now($_) }
		grep { (length($path) == 0) || /^\Q$path\E(?:\/|$)/ }
		keys %{$self->dir()}
	);
}

sub get_tree_paths_then {
	my ($self, $revision, $path) = @_;
	return(
		sort { (length($a) <=> length($b)) || ($a cmp $b) }
		grep { $self->path_exists_then($revision, $_) }
		grep { (length($path) == 0) || /^\Q$path\E(?:\/|$)/ }
		keys %{$self->dir()}
	);
}

sub get_tree_changes_then {
	my ($self, $revision, $path) = @_;
	return(
		grep { $_->exists() }
		map  { $self->get_path_change_then($revision, $_) }
		grep { (length($path) == 0) || /^\Q$path\E(?:\/|$)/ }
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

sub get_path_change_then {
	my ($self, $revision, $path) = @_;

	return unless exists $self->dir()->{$path};

	my $changes = $self->dir()->{$path};
	my $i = @$changes;

	while ($i--) {
		next if $changes->[$i]->revision() > $revision;
		return $changes->[$i];
	}

	# Doesn't exist.
	return;
}

sub get_entity_then {
	my ($self, $revision, $path) = @_;

	# Find the described change.  Return it if it's an entity.
	my $change_then = $self->get_path_change_then($revision, $path);

	return $change_then if $change_then->is_entity();

	# Otherwise jump to the entity holding the change.
	my $entity_path = $change_then->path_lop();
	return $self->get_path_change_then($revision, $entity_path);
}

sub map_entity_names {
	my ($self, $entity_name_map) = @_;
	foreach my $changes (values %{$self->dir()}) {
		foreach my $change (@$changes) {
			next unless exists $entity_name_map->{$change->entity_name()};
			$change->entity_name($entity_name_map->{$change->entity_name()});
		}
	}
}

sub get_copy_sources_then {
	my ($self, $revision) = @_;
	return {} unless exists $self->copy_sources()->{$revision};
	return $self->copy_sources()->{$revision};
}

1;
