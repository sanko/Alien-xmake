use v5.40;

#~ use lib 'C:\Users\S\Documents\GitHub\Alien-Xmake\lib';
use blib;
use Alien::Xrepo;
$|++;
my $audio    = 'C:\Users\S\AppData\Local\.xmake\packages\c\csfml\2.6.1\38ea7a5d8b204d54ad2ecca8c871bb20\bin\csfml-audio-2.dll';
my $graphics = 'C:\Users\S\AppData\Local\.xmake\packages\c\csfml\2.6.1\38ea7a5d8b204d54ad2ecca8c871bb20\bin\csfml-graphics-2.dll';
my $network  = 'C:\Users\S\AppData\Local\.xmake\packages\c\csfml\2.6.1\38ea7a5d8b204d54ad2ecca8c871bb20\bin\csfml-network-2.dll';
my $system   = 'C:\Users\S\AppData\Local\.xmake\packages\c\csfml\2.6.1\38ea7a5d8b204d54ad2ecca8c871bb20\bin\csfml-system-2.dll';
my $window   = 'C:\Users\S\AppData\Local\.xmake\packages\c\csfml\2.6.1\38ea7a5d8b204d54ad2ecca8c871bb20\bin\csfml-window-2.dll';
#
my $window3 = 'C:\Users\S\AppData\Local\.xmake\packages\s\sfml\3.0.1\9fb8d83a6e424277b28fac860b80fad2\bin\sfml-window-3.dll';
#
use Affix;
#
typedef sfWindowState => Enum [qw[sfWindowed svFullscreen]];
typedef sfContextSettings => Struct [
    depthBits         => UInt,
    stencilBits       => UInt,
    antiAliasingLevel => UInt,
    majorVersion      => UInt,
    minorVersion      => UInt,
    attributeFlags    => UInt32,
    sRgbCapable       => Bool
];
typedef sfVideoMode => Struct [ size         => Array [ Int, 2 ], bitsPerPixel => UInt ];
typedef sfTime      => Struct [ microseconds => Int64 ];
typedef sfWindowStyle => Enum [
    [ sfNone         => 0 ],                                   # No border / title bar (this flag and all others are mutually exclusive)
    [ sfTitlebar     => '1 << 0' ],                            # Title bar + fixed border
    [ sfResize       => '1 << 1' ],                            # Titlebar + resizable border + maximize button
    [ sfClose        => '1 << 2' ],                            # Titlebar + close button
    [ sfDefaultStyle => 'sfTitlebar | sfResize | sfClose' ]    # Default window style
];
#
affix $system, sfSleep => [ sfTime() ], Void;
affix $window, sfWindow_create => [ sfVideoMode(), String, UInt32, Int, Pointer [ sfContextSettings() ] ], Pointer [Void];

#~ my $win = sfWindow_create( { size => [ 640, 480 ]  }, "Hi", sfDefaultStyle(), sfWindowed(), {} );
#~ sfSleep( { microseconds => 3000000 } );
#
warn `nm $window3`;
affix $window3, [ '??0Window@sf@@QEAA@XZ' => 'new_Window' ] => [],
    Pointer [Void];

#~ sf::sleep(sf::seconds(3));
__END__
# Initialize
my $repo = Alien::Xrepo->new( verbose => 1 );
$repo->update_repo;
my $nuklear = $repo->install('csfml', '>=3.0.0');
use Affix;
use Affix::Wrap;

#~ warn  $nuklear->find_header('termcolor.hpp');

#~ use Data::Dump;
#~ ddx $webui;
#~ ddx $webui->_data_printer;
#~ ddx $webui->includedirs;
my $lib = $nuklear->libpath;
warn $lib;


system 'nm', $lib;

        # Parse headers and install symbols into the current package
        Affix::Wrap->new(
            project_files => [ $nuklear->find_header('termcolor.hpp') ],
            #~ include_dirs  => [ '/usr/local/include' ],
            types         => {
                #~ 'git_repository' => Pointer[Void], # Treat opaque struct as void pointer
                #~ 'git_off_t'      => Int64,         # Force specific integer width
            }
        )->wrap( $lib );
