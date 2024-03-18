requires 'perl', '5.020000';
requires 'Path::Tiny';
on 'test' => sub {
    requires 'Test2::V0';
    requires 'File::Temp';
};
on 'configure' => sub {
    requires 'Archive::Tar';
    requires 'CPAN::Meta';
    requires 'Module::Build';
    requires 'HTTP::Tiny';
    requires 'File::Spec::Functions';
    requires 'File::Basename';
    requires 'File::Which';
    requires 'File::Temp';
    requires 'Path::Tiny';
};
on 'develop' => sub {
    requires 'CPAN::Uploader';
    requires 'Code::TidyAll';
    requires 'Code::TidyAll::Plugin::ClangFormat';
    requires 'Code::TidyAll::Plugin::PodTidy';
    requires 'Perl::Tidy';
    requires 'Pod::Tidy';
    requires 'Test::CPAN::Meta';
    requires 'Test::MinimumVersion::Fast';
    requires 'Test::PAUSE::Permissions';
    requires 'Test::Pod' => 1.41;
    requires 'Test::Spellunker';
    requires 'Version::Next';
    requires 'Pod::Markdown::Github';
    requires 'Software::License::Artistic_2_0';
    requires 'Minilla';
};
