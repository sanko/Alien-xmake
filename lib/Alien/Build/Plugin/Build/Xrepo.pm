package Alien::Build::Plugin::Build::Xrepo;

use strict;
use warnings;
use 5.008004;
use Alien::Build::Plugin;
use Carp ();
use Cwd ();
use Path::Tiny ();
use File::Spec ();

our $VERSION = '0.9.5';

# The most recent build a plugin hook ran for.  Replace::Interpolate helper subs
# are invoked with no arguments, so flag/version helpers resolve the build here.
our $XREPO_BUILD;

# ABSTRACT: Build and gather xrepo packages in an alienfile

has '+packages' => sub { Carp::croak 'packages is a required property' };
has name       => undef;
has version    => undef;
has kind       => undef;
has root       => undef;
has ffi        => 0;
has verbose    => 0;
has repo       => undef;

sub init
{
  my($self, $meta) = @_;
  my $verbose = $self->verbose;

  $meta->add_requires('configure', 'Alien::Build' => '2.84');
  $meta->add_requires('configure', 'Alien::Xrepo' => '0.09.05');

  require Alien::Xrepo;
  require Alien::Xrepo::Build::Recipe;
  require Alien::Xmake;

  my $recipe = Alien::Xrepo::Build::Recipe->new(
    (defined $self->name ? (name => $self->name) : ()),
    packages => $self->packages,
  );

  my %ambient;
  $ambient{version} = $self->version if defined $self->version;
  $ambient{kind}    = $self->kind    if defined $self->kind;

  my $repo    = $self->repo;
  my $engine;
  my $engine_for = sub {
    return $engine if defined $engine;
    if (ref $repo eq 'CODE')
    {
      $engine = $repo->();
    }
    elsif (ref $repo)
    {
      $engine = $repo;
    }
    elsif (defined $repo)
    {
      $engine = $repo->new();
    }
    else
    {
      $engine = Alien::Xrepo->new( root => $self->root, verbose => $verbose );
    }
    $engine;
  };

  # probe: xrepo is the installer, so a probe always ends at a share install.
  # (Alien::Build ignores probe errors, so xrepo availability is checked in the
  # download stage, where a failure actually aborts the build.)
  $meta->register_hook(probe => sub { 'share' });

  # download: this plugin fetches no archives; the "download" is xrepo producing
  # the package trees.  The hook is *registered* (not a default) so that the
  # Alien::Build download wrapper runs it inside an isolated workspace and records
  # install_prop->{download}/{complete}; each package is installed into the store
  # and exported into this workspace.
  $meta->register_hook(download => sub {
    my($build) = @_;
    $XREPO_BUILD = $build;

    unless (ref $repo)
    {
      require File::Which;
      my $xrepo = eval { Alien::Xmake->new->xrepo } || 'xrepo';
      my $ok = File::Spec->file_name_is_absolute($xrepo)
        ? (-e $xrepo)
        : File::Which::which($xrepo);
      die "Alien::Build::Plugin::Build::Xrepo: could not locate xrepo ($xrepo). " .
          'Install xmake, or inject an engine via the repo property.' unless $ok;
    }

    my $r    = $engine_for->();
    my $src  = Cwd::getcwd();

    my %packages;
    my %errors;
    for my $name ($recipe->packages)
    {
      # a per-package recipe version wins; otherwise the ambient plugin version
      # (the alienfile `version` property) is the install-time default.
      my $version = $recipe->version_for($name);
      $version = $ambient{version} unless defined $version;
      my %opts    = $recipe->opts_for($name, %ambient);
      my $info;
      eval { $info = $r->install($name, $version, %opts) };
      if ($@)
      {
        $errors{$name} = "$@";
        warn "[xrepo] $name failed to install: $@\n";
        next;
      }
      if (ref $info && eval { $info->can('_data_printer') })
      {
        $packages{$name} = $info->_data_printer(undef);
      }
      my $target = Path::Tiny->new($src)->child($name);
      $target->mkpath;
      eval { $r->export($name, $version, %opts, packagedir => $target->stringify) };
      warn "[xrepo] $name could not be exported: $@\n" if $@;
    }

    # share verification counts files, so write a manifest even for one package.
    Path::Tiny->new($src)->child('xrepo.manifest')->spew_utf8( join "\n", $recipe->packages );

    my $xrepo = $build->install_prop->{xrepo} ||= {};
    $xrepo->{packages}     = \%packages;
    $xrepo->{errors}       = \%errors;
    $xrepo->{download_dir} = $src;

    die 'Alien::Build::Plugin::Build::Xrepo: no packages installed successfully' unless %packages;
  });

  # extract: the build stage runs inside a fresh directory that must hold the
  # fetched payload, so carry the download workspace into the extract workspace
  # and leave a directory behind for the build verification.
  $meta->default_hook(extract => sub {
    my($build) = @_;
    $XREPO_BUILD = $build;
    my $xrepo = $build->install_prop->{xrepo};
    die 'Alien::Build::Plugin::Build::Xrepo: the plugin download stage must run before extract'
      unless $xrepo && defined $xrepo->{download_dir};
    my $src = Path::Tiny->new($xrepo->{download_dir});
    my $dst = Path::Tiny->new(Cwd::getcwd());
    for my $child ($src->children)
    {
      next if $child->basename eq '.';
      my $out = $dst->child($child->basename);
      $child->is_dir ? _copy_tree($child, $out) : $child->copy($out);
    }
    1;
  });

  # build: assemble the fetched package trees into the staging prefix.  Package
  # bin dirs are merged into <prefix>/bin so Alien::Base->bin_dir and the FFI
  # dynamic_libs search can find dlls without per-package path guessing.
  $meta->default_hook(build => sub {
    my($build) = @_;
    $XREPO_BUILD = $build;
    my $xrepo  = $build->install_prop->{xrepo};
    die 'Alien::Build::Plugin::Build::Xrepo: the plugin download stage must run before build'
      unless $xrepo && defined $xrepo->{download_dir};
    my $src    = Path::Tiny->new($xrepo->{download_dir});
    my $prefix = Path::Tiny->new($build->install_prop->{prefix})
      || die 'Alien::Build::Plugin::Build::Xrepo: prefix is not set';
    $prefix->mkpath;

    my %exported;
    for my $name ($recipe->packages)
    {
      my $from = $src->child($name);
      next unless -d $from;
      my $to = $prefix->child($name);
      $to->mkpath;
      for my $child ($from->children)
      {
        my $dest = $to->child($child->basename);
        $child->is_dir ? _copy_tree($child, $dest) : $child->copy($dest);
      }
      $exported{$name} = $to->stringify;

      my $bin = $to->child('bin');
      next unless -d $bin;
      my $destbin = $prefix->child('bin');
      $destbin->mkpath;
      for my $file ($bin->children)
      {
        my $out = $destbin->child($file->basename);
        next if -e $out;
        $file->copy($out);
      }
    }

    my $manifest = $src->child('xrepo.manifest');
    $manifest->remove if -e $manifest;

    $xrepo->{exported} = \%exported;
  });

  # gather: translate the assembled package roots into Alien::Build runtime props.
  $meta->register_hook(gather_share => sub {
    my($build) = @_;
    $XREPO_BUILD = $build;
    my $xrepo = $build->install_prop->{xrepo};
    my $data  = $xrepo && $xrepo->{packages};
    my $exp   = $xrepo && $xrepo->{exported};
    die 'Alien::Build::Plugin::Build::Xrepo: no package data to gather; ' .
        'did the plugin download/build stages run?'
      unless $data && %$data && $exp && %$exp;

    my $rp = $build->runtime_prop;
    my @pkgs = $recipe->packages;

    if (my $p = _pkg_props($data->{ $pkgs[0] }, $exp->{ $pkgs[0] }))
    {
      $rp->{$_} = $p->{$_} for qw( cflags cflags_static libs libs_static );
      $rp->{version} = $p->{version} if defined $p->{version};
      $rp->{bin_dir} = _reroot_bins($build, $p->{bin_dir}) if $p->{bin_dir};
    }

    if (@pkgs > 1)
    {
      my %alt;
      for my $name (@pkgs[1 .. $#pkgs])
      {
        my $p = _pkg_props($data->{$name}, $exp->{$name});
        $p->{bin_dir} = _reroot_bins($build, $p->{bin_dir}) if $p && $p->{bin_dir};
        $alt{$name} = $p if $p;
      }
      $rp->{alt} = \%alt if keys %alt;
    }
  });

  if ($self->ffi)
  {
    $meta->register_hook(gather_ffi => sub {
      my($build) = @_;
      $XREPO_BUILD = $build;
      my $xrepo = $build->install_prop->{xrepo} or return;
      my $data  = $xrepo->{packages} or return;
      my $exp   = $xrepo->{exported} or return;
      my $rp    = $build->runtime_prop;

      my $primary = $data->{( $recipe->packages )[0]};
      my @links = @{ $primary->{links} || [] };
      $rp->{ffi_name} ||= $links[0] if $links[0];

      my @dyn;
      for my $dir (values %$exp)
      {
        for my $sub (qw( bin lib ))
        {
          my $d = Path::Tiny->new($dir)->child($sub);
          next unless -d $d;
          push @dyn, map { $_->stringify } grep { $_->basename =~ /\.(?:dll|so|dylib)$/i } $d->children;
        }
      }
      $rp->{dynamic_libs} ||= \@dyn if @dyn;
    });
  }

  # helpers: the resolved xmake/xrepo binaries and the gathered package flags.
  my $intr = $meta->interpolator;
  $intr->add_helper(xrepo => sub { Alien::Xmake->new->xrepo });
  $intr->add_helper(xmake => sub { Alien::Xmake->new->exe });
  $intr->add_helper(xrepo_cflags => sub {
    my $b = $XREPO_BUILD;
    defined $b ? ($b->runtime_prop->{cflags} || '') : '';
  });
  $intr->add_helper(xrepo_libs => sub {
    my $b = $XREPO_BUILD;
    defined $b ? ($b->runtime_prop->{libs} || '') : '';
  });
  $intr->add_helper(xrepo_version => sub {
    my $b = $XREPO_BUILD;
    defined $b ? ($b->runtime_prop->{version} || '') : '';
  });
  $intr->add_helper(xrepo_dynamic_libs => sub {
    my $b = $XREPO_BUILD;
    my $d = defined $b ? $b->runtime_prop->{dynamic_libs} : undef;
    return '' unless $d;
    join ' ', @$d;
  });

  $self;
}

# Translate an exported package root plus its install-time info into the runtime
# property surface a consumer expects.  Paths are relative to the staging prefix,
# so Alien::Build's Core::Gather handles the prefix rewrite after the share
# install is mirrored into place.
# core gather rewrites only the -I/-L flag paths, so bin_dir entries are
# re-rooted here from the staging prefix to the final runtime prefix.
sub _reroot_bins
{
  my($build, $bins) = @_;
  return $bins unless $bins;
  my $root = $build->install_prop->{prefix};
  my $rr   = $build->runtime_prop->{prefix};
  return $bins unless defined $root && defined $rr;
  [ map {
      my $rel = File::Spec->abs2rel($_, $root);
      File::Spec->catdir($rr, $rel);
    } @$bins ];
}

sub _copy_tree
{
  my($src, $dst) = @_;
  $dst->mkpath;
  for my $child ($src->children)
  {
    my $out = $dst->child($child->basename);
    $child->is_dir ? _copy_tree($child, $out) : $child->copy($out);
  }
  1;
}

sub _pkg_props
{
  my($info, $dir) = @_;
  return undef unless $info && $dir;

  my $t     = Path::Tiny->new($dir);
  my @inc   = ();
  my @ldirs = ();
  my @bins  = ();

  push @inc,   $t->child('include')->stringify if -d $t->child('include');
  push @ldirs, $t->child('lib')->stringify     if -d $t->child('lib');
  push @bins,  $t->child('bin')->stringify     if -d $t->child('bin');
  push @inc,   $t->stringify if !@inc;
  push @ldirs, $t->stringify if !@ldirs;

  my $cflags = join ' ', map { "-I$_" } @inc;
  my $libs   = join ' ', map { "-L$_" } @ldirs;
  $libs .= ' ' . join ' ', map { "-l$_" } @{ $info->{links} || [] };

  {   cflags        => $cflags,
      cflags_static => $cflags,
      libs          => $libs,
      libs_static   => $libs,
      version       => $info->{version},
      bin_dir       => \@bins,
  };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Alien::Build::Plugin::Build::Xrepo - Build and gather xrepo packages in an alienfile

=head1 VERSION

version 0.9.5

=head1 SYNOPSIS

 use alienfile;

 plugin 'Build::Xrepo' => (
   packages => [ 'zstd' ],
 );

 # or, with per-package options and FFI:

 plugin 'Build::Xrepo' => (
   packages => [
     'zstd',
     { name => 'libsdl3', version => '3.4.12', kind => 'shared' },
   ],
   ffi  => 1,
 );

=head1 DESCRIPTION

This plugin lets an L<alienfile>-based L<Alien> distribution install its
packages through L<xrepo|https://packages.xmake.io/> instead of downloading,
extracting and compiling source archives.  It is the L<Alien::Build> mirror of
the L<Alien::Xrepo::Build> engine: the C<download> stage asks xrepo for the
packages (through L<Alien::Xrepo>), the C<build> stage assembles the exported
package trees into the staging prefix, and the C<gather> stages translate them
into the standard L<Alien::Build> runtime properties (C<cflags>, C<libs>,
C<version>, C<bin_dir>, plus C<alt> for multi-package recipes).

The plugin always returns C<share> from the C<probe> stage: xrepo is the
installer.  The xrepo executable is located during the C<download> stage and a
missing executable aborts that stage with a clear error instead of guessing.

=head1 PROPERTIES

=head2 packages

The packages to install, in recipe order.  Each entry is a package name or a
hashref of per-package options (name, version, kind, plat, arch, toolchain,
configs, ... -- the same keys the L<Alien::Xrepo::Build::Recipe> understands).
The first entry is the primary package.

=head2 version

An ambient version constraint (e.g. C<1.5.6>) folded into every package that
does not pin its own C<version>.

=head2 kind

An ambient package kind (C<shared> or C<static>) folded into every package that
does not pin its own C<kind>.

=head2 root

An optional xrepo store root (C<XMAKE_PKG_INSTALLDIR>).  Defaults to whatever
the system xrepo configuration uses.

=head2 ffi

When true, a C<gather_ffi> hook is registered that populates
C<%{.runtime.ffi_name}> and C<%{.runtime.dynamic_libs}> from the installed
packages, for use by C<build_ffi> consumers.

=head2 verbose

Echo xrepo commands as they run (passed through to L<Alien::Xrepo>).

=head2 repo

An optional L<Alien::Xrepo>-compatible engine (an object, a class name, or a
code ref that returns one).  Mainly useful for testing the plugin against a
spy without a real xrepo install.  When unset, the plugin builds an
L<Alien::Xrepo> with C<root> and C<verbose>.

=head1 HELPERS

=over 4

=item C<%{xrepo}>

The resolved path to the C<xrepo> executable.

=item C<%{xmake}>

The resolved path to the C<xmake> executable.

=item C<%{xrepo_cflags}>

The gathered include flags for the primary package.

=item C<%{xrepo_libs}>

The gathered link flags for the primary package.

=item C<%{xrepo_version}>

The gathered version of the primary package.

=item C<%{xrepo_dynamic_libs}>

The gathered dynamic library paths (when the C<ffi> property is enabled).

=back

=head1 SEE ALSO

L<Alien::Build>, L<alienfile>, L<Alien::Build::Plugin>,
L<Alien::Build::Manual::PluginAuthor>, L<Alien::Xrepo>,
L<Alien::Xrepo::Build>, L<Alien::Xrepo::Build::Recipe>, L<Alien::Xrepo::Runtime>

=head1 AUTHOR

Author: Sanko Robinson E<lt>sanko@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2026 by Sanko Robinson.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut