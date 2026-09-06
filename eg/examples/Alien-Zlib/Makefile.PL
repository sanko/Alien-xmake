use v5.40;
use ExtUtils::MakeMaker;
use Alien::Build::MM 2.84;

# Alien::Build::MM loads the alienfile, folds its prereqs into WriteMakefile,
# and adds Makefile targets that probe/download/build the alien during install.
my $abmm = Alien::Build::MM->new;

WriteMakefile( $abmm->mm_args(
    ABSTRACT => 'Build & install zlib (shared) via the Build::Xrepo Alien::Build plugin',
    DISTNAME => 'Alien-Zlib',
    NAME     => 'Alien::Zlib',
    VERSION  => '0.001',
) );

sub MY::postamble {
    $abmm->mm_postamble(@_);
}

sub MY::install {
    $abmm->mm_install(@_);
}