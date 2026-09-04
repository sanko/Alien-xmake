use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Config;
use Alien::Xrepo;
use experimental 'class';
#
my $repo = Alien::Xrepo->new( verbose => 0 );

# Grab the resolved xmake exe the same way _argv does (via the field object).
my $xmake_exe = eval { Alien::Xmake->new->exe } // 'xmake';

subtest 'enum-cli-methods' => sub {
    isa_ok $repo, ['Alien::Xrepo'], 'Alien::Xrepo object';
    ok $repo->can('_argv'), 'has _argv';
    ok $repo->can('_build_args'), 'has _build_args';
    ok $repo->can('_confirm_args'), 'has _confirm_args';
};

subtest '_argv prefix and flags-before-spec invariant' => sub {

    # Every action with a trailing package spec: flags come first, then the
    # (possibly versioned) spec, and NOTHING follows the spec.
    for my $case (
        [ install    => [qw[-y -k shared]],                'zlib'        ],
        [ install    => [qw[-y]],                          'libsdl3_ttf' ],
        [ remove     => [qw[-y --all]],                    'zlib'        ],
        [ fetch      => [qw[--json -k shared]],            'zlib 1.2.11' ],
        [ info       => [qw[-k static]],                   'zlib'        ],
        [ scan       => [qw[--format=plain]],              'zlib'        ],
        [ download   => [qw[-y -o /tmp/o]],                'zlib'        ],
        [ import     => [qw[-y -i /tmp/i]],                'zlib'        ],
        [ export     => [qw[-y -o /tmp/o]],                'zlib'        ],
        [ 'add-repo' => [qw[-y]],                          'myrepo', 'https://example.com/repo.git' ],
        [ search     => [qw[--addon]],                     'zlib'        ],
    ) {
        my ( $action, $flags, @spec ) = @$case;
        my @argv = $repo->_argv( $action, $flags, @spec );
        is $argv[0], $xmake_exe,         "$action: argv starts with the xmake exe";
        is [ @argv[ 1 .. 3 ] ], [ qw[lua private.xrepo], $action ], "$action: runs `xmake lua private.xrepo $action`";

        # The spec (versioned single-string or multi-token) is the trailing argv.
        my @tail = @argv[ 4 .. $#argv ];
        my $n    = @spec;
        my $start = $#tail + 1 - $n;
        is [ @tail[ $start .. $#tail ] ], [@spec], "$action: package spec is the trailing argument(s)";

        # No dash-prefixed flag may appear after the first spec token: that is
        # exactly the parser-leak the invariant guards against.
        my $first_spec = $#argv + 1 - $n;
        for my $i ( $first_spec + 1 .. $#argv ) {
            unlike $argv[$i], qr{^-}, "$action: no flag follows the spec";
        }
    }

    # A versioned spec stays a single argv element so spaces never split argv.
    my @argv = $repo->_argv( 'install', ['-y'], 'libsdl3_ttf >=3.2.2');
    is $argv[-1], 'libsdl3_ttf >=3.2.2', 'versioned spec is a single trailing element';
};

subtest '_build_args includes uses the OS path separator' => sub {

    # xrepo's install.lua splits `--includes` with path.splitenv and rejoins with
    # path.joinenv -- both keyed off the platform path separator, never a comma.
    my $sep = $Config{path_sep};

    my @single = $repo->_build_args( { includes => 'recipe.lua' } );
    my ($flag_single) = grep {/^--includes=/} @single;
    is $flag_single, '--includes=recipe.lua', 'scalar includes passed through verbatim';

    my @multi = $repo->_build_args( { includes => [ 'a.lua', 'b.lua' ] } );
    my ($flag_multi) = grep {/^--includes=/} @multi;
    is $flag_multi, "--includes=a.lua${sep}b.lua", "array includes joined with path separator ($sep)";
    unlike $flag_multi, qr{,}, 'array includes never joined with a comma';

    # Paths containing the separator would split, but normal single paths are fine.
    if ( $^O eq 'MSWin32' ) {
        my @win = $repo->_build_args( { includes => 'C:\path with space\recipe.lua' } );
        my ($flag_win) = grep {/^--includes=/} @win;
        is $flag_win, '--includes=C:\path with space\recipe.lua', 'Windows path passes through verbatim';
    }
};

subtest '_build_args auto-confirm flags' => sub {

    my @default = $repo->_build_args( {} );
    is [ grep {/^-y$/} @default ], [], 'no -y when neither yes nor confirm is given';

    my @yes = $repo->_build_args( { yes => 1 } );
    is [ grep {/^-y$/} @yes ], [ '-y' ], '-y emitted for yes => 1';

    my @yes0 = $repo->_build_args( { yes => 0 } );
    is [ grep {/^-y$/} @yes0 ], [], 'no -y for yes => 0';

    my @confirm = $repo->_build_args( { confirm => 'never' } );
    is [ grep {/^--confirm=/} @confirm ], [ '--confirm=never' ], '--confirm= emitted for confirm =>';
    is [ grep {/^-y$/} @confirm ], [], 'confirm suppresses -y';

    my @both = $repo->_build_args( { yes => 1, confirm => 'never' } );
    is [ grep {/^--confirm=/} @both ], [ '--confirm=never' ], 'confirm wins over yes';
    is [ grep {/^-y$/} @both ], [], 'no -y when confirm is set';
};

subtest '_confirm_args default-confirm for mutating actions' => sub {

    # install/uninstall/download/import/export auto-confirm by default so a
    # captured install never hangs, but an explicit choice is honored.
    is [ $repo->_confirm_args( {} ) ],                [ '-y' ],     'default mutating action confirms';
    is [ $repo->_confirm_args( { yes => 0 } ) ],      [],            'yes => 0 opts out';
    is [ $repo->_confirm_args( { yes => 1 } ) ],      [],            'yes => 1 handled by _build_args';
    is [ $repo->_confirm_args( { confirm => 'never' } ) ], [],        'confirm opts out';
};

# End-to-end-ish: the full install argv for the SDL3 TTF recipe (the case that
# motivated `--includes`) has the recipe as a flag and the package last.
subtest 'sdl3 ttf install argv' => sub {
    my $recipe = 'C:/dir/libsdl3_ttf.lua';
    my @argv   = $repo->_argv( 'install', [ '-y', '-k', 'shared', "--includes=$recipe" ], 'libsdl3_ttf' );
    is $argv[-1], 'libsdl3_ttf', 'ttf package is the trailing spec';
    my ($inc) = grep {/^--includes=/} @argv;
    is $inc, "--includes=$recipe", '--includes recipe precedes the spec';
    my $inc_at = -1;
    for my $i ( 0 .. $#argv ) { $inc_at = $i if $argv[$i] eq $inc; }
    ok $inc_at >= 0 && $inc_at < $#argv, 'includes flag comes before the package spec';
};
#
done_testing;
