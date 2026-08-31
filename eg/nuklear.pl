use v5.40;
use blib;
use warnings;
use strict;
use Affix          qw[:all];
use File::Basename qw(dirname);
use File::Spec;

# nuklear window-flags
use constant {
    NK_WINDOW_BORDER      => 0x01,
    NK_WINDOW_MOVABLE     => 0x02,
    NK_WINDOW_SCALABLE    => 0x04,
    NK_WINDOW_CLOSABLE    => 0x08,
    NK_WINDOW_MINIMIZABLE => 0x10,
    NK_WINDOW_TITLE       => 0x40,
    NK_TEXT_LEFT          => 0x11,
    NK_TEXT_CENTERED      => 0x12,
    NK_TEXT_RIGHT         => 0x14,
};
my $dll = File::Spec->catfile( dirname(__FILE__), 'nuklear', 'build', 'windows', 'x64', 'release', 'nk_win.dll' );
die "nk_win.dll not found at $dll -- run `xmake -r` in eg/nuklear first\n" unless -f $dll;

# --- wrapper (single window, message pump) ---
affix $dll, 'nk_win_init',     [ WString, Int, Int, String, Int ]                           => Int;
affix $dll, 'nk_win_poll',     []                                                           => Void;
affix $dll, 'nk_win_running',  []                                                           => Int;
affix $dll, 'nk_win_render',   [ Int, Int, Int, Int ]                                       => Void;
affix $dll, 'nk_win_shutdown', []                                                           => Void;
affix $dll, 'nk_win_context',  []                                                           => Pointer [Void];
affix $dll, 'nk_win_begin',    [ Pointer [Void], String, Float, Float, Float, Float, UInt ] => Int;

# --- nuklear API (direct exports) ---
affix $dll, 'nk_end',                [ Pointer [Void] ]                                => Void;
affix $dll, 'nk_label',              [ Pointer [Void], String, Int ]                   => Void;
affix $dll, 'nk_button_label',       [ Pointer [Void], String ]                        => Int;
affix $dll, 'nk_layout_row_dynamic', [ Pointer [Void], Float, Int ]                    => Void;
affix $dll, 'nk_slide_float',        [ Pointer [Void], Float, Float, Float, Float ]    => Float;
affix $dll, 'nk_checkbox_label',     [ Pointer [Void], String, Pointer [Int] ]         => Int;
affix $dll, 'nk_option_label',       [ Pointer [Void], String, Int ]                   => Int;
affix $dll, 'nk_progress',           [ Pointer [Void], Pointer [Size_t], Size_t, Int ] => Int;
affix $dll, 'nk_group_begin',        [ Pointer [Void], String, Int ]                   => Int;
affix $dll, 'nk_group_end',          [ Pointer [Void] ]                                => Void;
affix $dll, 'nk_spacing',            [ Pointer [Void], Int ]                           => Void;
die 'failed to open window' unless nk_win_init( 'Affix + Nuklear', 900, 640, 'Arial', 14 );
my $ctx      = nk_win_context();
my $clicks_a = 0;
my $clicks_b = 0;
my $red      = 20;
my $green    = 60;
my $show_bar = 1;
my $progress = 25;
my $choice   = 0;
my @log      = ('window opened');

sub log_line ($text) {
    push @log, $text;
    shift @log while @log > 8;
}
my $WIN_FLAGS = NK_WINDOW_TITLE | NK_WINDOW_BORDER | NK_WINDOW_MOVABLE | NK_WINDOW_SCALABLE | NK_WINDOW_CLOSABLE;
while ( nk_win_running() ) {
    nk_win_poll();
    if ( nk_win_begin( $ctx, 'Demo', 40, 40, 480, 480, $WIN_FLAGS ) ) {
        nk_layout_row_dynamic( $ctx, 25, 1 );
        nk_label( $ctx, 'Nuklear driven from Perl via Affix', NK_TEXT_LEFT );
        nk_layout_row_dynamic( $ctx, 30, 2 );
        if ( nk_button_label( $ctx, 'Button A' ) ) { $clicks_a++; log_line 'pressed Button A' }
        if ( nk_button_label( $ctx, 'Button B' ) ) { $clicks_b++; log_line 'pressed Button B' }
        nk_layout_row_dynamic( $ctx, 25, 1 );
        nk_label( $ctx, sprintf( 'A:%d  B:%d', $clicks_a, $clicks_b ), NK_TEXT_LEFT );
        nk_layout_row_dynamic( $ctx, 25, 2 );
        nk_label( $ctx, 'Red', NK_TEXT_LEFT );
        $red = nk_slide_float( $ctx, 0, $red, 255, 1 );
        nk_label( $ctx, 'Green', NK_TEXT_LEFT );
        $green = nk_slide_float( $ctx, 0, $green, 255, 1 );
        nk_layout_row_dynamic( $ctx, 25, 1 );

        if ( nk_checkbox_label( $ctx, 'Show progress bar', \$show_bar ) ) {
            log_line $show_bar ? 'progress bar on' : 'progress bar off';
        }
        if ($show_bar) {
            nk_progress( $ctx, \$progress, 100, 1 );
        }
        nk_layout_row_dynamic( $ctx, 25, 1 );
        if ( nk_option_label( $ctx, 'Option 1', $choice == 0 ) ) { $choice = 0 }
        if ( nk_option_label( $ctx, 'Option 2', $choice == 1 ) ) { $choice = 1 }
        if ( nk_option_label( $ctx, 'Option 3', $choice == 2 ) ) { $choice = 2 }
        nk_spacing( $ctx, 1 );
        nk_layout_row_dynamic( $ctx, 20, 1 );
        if ( nk_group_begin( $ctx, 'Log', 0 ) ) {
            nk_layout_row_dynamic( $ctx, 18, 1 );
            nk_label( $ctx, $_, NK_TEXT_LEFT ) for @log;
            nk_group_end($ctx);
        }
    }
    nk_end($ctx);
    nk_win_render( int($red), int($green), 40, 255 );
}

END {
    nk_win_shutdown() if defined &nk_win_shutdown;
}
