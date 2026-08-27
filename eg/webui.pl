use v5.40;

#~ use lib 'C:\Users\S\Documents\GitHub\Alien-Xmake\lib';
use blib;
use Alien::Xrepo;
$|++;

# Initialize
my $repo = Alien::Xrepo->new( verbose => 0 );
$repo->update_repo;
my $webui = $repo->install('webui');
use Affix;
use Affix::Wrap;

#~ use Data::Dump;
#~ ddx $webui;
#~ ddx $webui->_data_printer;
#~ ddx $webui->includedirs;
my $lib = $webui->libpath;

=head2 webui_browsers

-- Enums ---------------------------

=cut

typedef webui_browsers => Enum [
    [ NoBrowser     => 0 ],
    [ AnyBrowser    => 1 ],
    [ Chrome        => 2 ],
    [ Firefox       => 3 ],
    [ Edge          => 4 ],
    [ Safari        => 5 ],
    [ Chromium      => 6 ],
    [ Opera         => 7 ],
    [ Brave         => 8 ],
    [ Vivaldi       => 9 ],
    [ Epic          => 10 ],
    [ Yandex        => 11 ],
    [ ChromiumBased => 12 ]
];
typedef webui_runtimes => Enum [qw[None Deno NodeJS]];
typedef webui_events =>
    Enum [ 'WEBUI_EVENT_DISCONNECTED', 'WEBUI_EVENT_CONNECTED', 'WEBUI_EVENT_MOUSE_CLICK', 'WEBUI_EVENT_NAVIGATION', 'WEBUI_EVENT_CALLBACK' ];
typedef webui_event_t => Struct [ window => Size_t, event_type => Size_t, element => Pointer [Char], event_number => Size_t, bind_id => Size_t ];
affix $lib, webui_new_window        => [], Size_t;
affix $lib, webui_new_window_id     => [Size_t], Size_t;
affix $lib, webui_get_new_window_id => [], Size_t;
affix $lib,
    webui_bind => [ Size_t, Pointer [Char], Callback [ [ Pointer [ webui_event_t() ] ] => Void ] ],
    Size_t;
affix $lib, webui_show                    => [ Size_t, Pointer [Char] ], Bool;
affix $lib, webui_show_browser            => [ Size_t, Pointer [Char], Size_t ], Bool;
affix $lib, webui_set_kiosk               => [ Size_t, Bool ], Void;
affix $lib, webui_wait                    => [], Void;
affix $lib, webui_close                   => [Size_t], Void;
affix $lib, webui_destroy                 => [Size_t], Void;
affix $lib, webui_exit                    => [], Void;
affix $lib, webui_set_root_folder         => [ Size_t, Pointer [Char] ], Bool;
affix $lib, webui_set_default_root_folder => [ Pointer [Char] ], Bool;
affix $lib,
    webui_set_file_handler => [ Size_t, Callback [ [ Pointer [Char], Pointer [Int] ] => Pointer [Void] ] ],
    Void;
affix $lib, webui_is_shown              => [Size_t], Bool;
affix $lib, webui_set_timeout           => [Size_t], Void;
affix $lib, webui_set_icon              => [ Size_t, Pointer [Char], Pointer [Char] ], Void;
affix $lib, webui_encode                => [ Pointer [Char] ], Pointer [Char];
affix $lib, webui_decode                => [ Pointer [Char] ], Pointer [Char];
affix $lib, webui_free                  => [ Pointer [Void] ], Void;
affix $lib, webui_malloc                => [Size_t], Pointer [Void];
affix $lib, webui_send_raw              => [ Size_t, Pointer [Char], Pointer [Void], Size_t ], Void;
affix $lib, webui_set_hide              => [ Size_t, Bool ], Void;
affix $lib, webui_set_size              => [ Size_t, UInt, UInt ], Void;
affix $lib, webui_set_position          => [ Size_t, UInt, UInt ], Void;
affix $lib, webui_set_profile           => [ Size_t, Pointer [Char], Pointer [Char] ], Void;
affix $lib, webui_get_url               => [Size_t], Pointer [Char];
affix $lib, webui_set_public            => [ Size_t, Bool ], Void;
affix $lib, webui_navigate              => [ Size_t, Pointer [Char] ], Void;
affix $lib, webui_clean                 => [], Void;
affix $lib, webui_delete_all_profiles   => [], Void;
affix $lib, webui_delete_profile        => [Size_t], Void;
affix $lib, webui_get_parent_process_id => [Size_t], Size_t;
affix $lib, webui_get_child_process_id  => [Size_t], Size_t;
affix $lib, webui_set_port              => [ Size_t, Size_t ], Bool;
affix $lib, webui_set_tls_certificate   => [ Pointer [Char], Pointer [Char] ], Bool;
affix $lib, webui_run                   => [ Size_t, Pointer [Char] ], Void;
affix $lib, webui_script                => [ Size_t, Pointer [Char], Size_t, Pointer [Char], Size_t ], Bool;
affix $lib, webui_set_runtime           => [ Size_t, Size_t ], Void;
affix $lib, webui_get_int_at            => [ Pointer [ webui_event_t() ], Size_t ], LongLong;
affix $lib, webui_get_int               => [ Pointer [ webui_event_t() ] ], LongLong;
affix $lib, webui_get_string_at         => [ Pointer [ webui_event_t() ], Size_t ], Pointer [Char];
affix $lib, webui_get_string            => [ Pointer [ webui_event_t() ] ], Pointer [Char];
affix $lib, webui_get_bool_at           => [ Pointer [ webui_event_t() ], Size_t ], Bool;
affix $lib, webui_get_bool              => [ Pointer [ webui_event_t() ] ], Bool;
affix $lib, webui_get_size_at           => [ Pointer [ webui_event_t() ], Size_t ], Size_t;
affix $lib, webui_get_size              => [ Pointer [ webui_event_t() ] ], Size_t;
affix $lib, webui_return_int            => [ Pointer [ webui_event_t() ], LongLong ], Void;
affix $lib, webui_return_string         => [ Pointer [ webui_event_t() ], Pointer [Char] ], Void;
affix $lib, webui_return_bool           => [ Pointer [ webui_event_t() ], Bool ], Void;
affix $lib,
    webui_interface_bind => [ Size_t, Pointer [Char], Callback [ [ Size_t, Size_t, Pointer [Char], Size_t, Size_t ] => Void ] ],
    Size_t;
affix $lib, webui_interface_set_response   => [ Size_t, Size_t, Pointer [Char] ], Void;
affix $lib, webui_interface_is_app_running => [], Bool;
affix $lib, webui_interface_get_window_id  => [Size_t], Size_t;
affix $lib, webui_interface_get_string_at  => [ Size_t, Size_t, Size_t ], Pointer [Char];
affix $lib, webui_interface_get_int_at     => [ Size_t, Size_t, Size_t ], LongLong;
affix $lib, webui_interface_get_bool_at    => [ Size_t, Size_t, Size_t ], Bool;
affix $lib, webui_interface_get_size_at    => [ Size_t, Size_t, Size_t ], Size_t;
#
sub events($e) {
    use Data::Dump;
    ddx $e;
    warn 'Event!';
    if ( $$e->{event_type} == WEBUI_EVENT_CONNECTED() ) {
        say 'Connected.';
    }
    elsif ( $$e->{event_type} == WEBUI_EVENT_DISCONNECTED() ) {
        say("Disconnected. \n");
    }
    elsif ( $$e->{event_type} == WEBUI_EVENT_MOUSE_CLICK() ) {
        say("Click. \n");
    }
    elsif ( $$e->{event_type} == WEBUI_EVENT_NAVIGATION() ) {
        say( "Starting navigation to: %s \n", e->data );
    }
}
#
my $win = webui_new_window();
webui_bind( $win, '', \&events );

#~ webui_bind($win, '', \&events);
sub _e { warn '!!!!!!!!!!!!!!_e'; }
webui_bind( $win, 'my_function_string', \&_e );
my $html = '<html><script src="webui.js"></script> Hello World from C! </html>';
$html = <<'HTML';
    <!DOCTYPE html>
	    <html>
	      <head>
	        <meta charset="UTF-8">
	        <script src="webui.js"></script>
	        <title>Call C from JavaScript Example</title>
	        <style>
	           body {
	                font-family: 'Arial', sans-serif;
	                color: white;
	                background: linear-gradient(to right, #507d91, #1c596f, #022737);
	                text-align: center;
	                font-size: 18px;
	            }
	            button, input {
	                padding: 10px;
	                margin: 10px;
	                border-radius: 3px;
	               border: 1px solid #ccc;
	                box-shadow: 0 3px 5px rgba(0,0,0,0.1);
	                transition: 0.2s;
	            }
	            button {
	                background: #3498db;
	                color: #fff;
	                cursor: pointer;
	                font-size: 16px;
	            }
	            h1 { text-shadow: -7px 10px 7px rgb(67 57 57 / 76%); }
	            button:hover { background: #c9913d; }
	            input:focus { outline: none; border-color: #3498db; }
	        </style>
	      </head>
	      <body>
	        <h1>WebUI - Call C from JavaScript</h1>
	        <p>Call C functions with arguments (<em>See the logs in your terminal</em>)</p>
	        <button onclick="my_function_string('Hello', 'World');">Call my_function_string()</button>
	        <br>
	        <button onclick="my_function_integer(123, 456, 789, 12345.6789);">Call my_function_integer()</button>
	        <br>
	        <button onclick="my_function_boolean(true, false);">Call my_function_boolean()</button>
	        <br>
	        <button onclick="my_function_raw_binary(new Uint8Array([0x41,0x42,0x43]), big_arr);">
	         Call my_function_raw_binary()</button>
	        <br>
	        <p>Call a C function that returns a response</p>
	        <button onclick="MyJS();">Call my_function_with_response()</button>
	        <div>Double: <input type="text" id="MyInputID" value="2"></div>
	        <script>
	          const arr_size = 512 * 1000;
	          const big_arr = new Uint8Array(arr_size);
	          big_arr[0] = 0xA1;
	          big_arr[arr_size - 1] = 0xA2;
	          function MyJS() {
	            const MyInput = document.getElementById('MyInputID');
	           const number = MyInput.value;
	            my_function_with_response(number, 2).then((response) => {
	                MyInput.value = response;
	            });
	          }
	        </script>
	      </body>
	    </html>
HTML
webui_set_size( $win, 800, 600 );
webui_show( $win, $html );
webui_wait();
webui_clean();
