--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Terminal_Interface.Curses;

with Definitions;  use Definitions;

package Display is

   package TIC renames Terminal_Interface.Curses;

   type summary_rec is
      record
         Initially : Natural;
         Built     : Natural;
         Failed    : Natural;
         Ignored   : Natural;
         Skipped   : Natural;
         elapsed   : String (1 .. 8);
         impulse   : Natural;
         pkg_hour  : Natural;
         load      : Float;
         swap      : Float;
      end record;

   type builder_rec is
      record
         id        : builders;
         shutdown  : Boolean;
         idle      : Boolean;
         slavid    : String (1 .. 2);
         Elapsed   : String (1 .. 8);
         LLines    : String (1 .. 7);
         phase     : String (1 .. 15);
         origin    : String (1 .. 37);
      end record;

   type history_rec is
      record
         id          : builders;
         slavid      : String (1 .. 2);
         run_elapsed : String (1 .. 8);
         action      : String (1 .. 8);
         pkg_elapsed : String (1 .. 8);
         origin      : String (1 .. 43);
         established : Boolean := False;
      end record;

   --  Initialize the curses screen.
   --  Returns False if no color support (curses not used at all)
   function launch_monitor (num_builders : builders) return Boolean;

   --  The build is done, return to the console
   procedure terminate_monitor;

   --  prints the summary header
   procedure summarize (data : summary_rec);

   --  Updates the status of a builder (contained in builder_rec)
   procedure update_builder (BR : builder_rec);

   --  After all the update_builder calls, call refresh to implement
   procedure refresh_builder_window;

   --  After all the history inserts, call refresh to implement
   procedure refresh_history_window;

   --  Insert history as builder finishes (shutdown, success, failure);
   procedure insert_history (HR : history_rec);

private

   type palette_rec is
      record
         palette   : TIC.Color_Pair;
         attribute : TIC.Character_Attribute_Set;
      end record;

   type builder_palette is array (builders) of palette_rec;
   type cyclic_range is range 1 .. 50;
   type dim_history is array (cyclic_range) of history_rec;

   history       : dim_history;
   history_arrow : cyclic_range := cyclic_range'Last;

   app_width     : TIC.Column_Count := 80;
   historyheight : TIC.Line_Position;
   zone_summary  : TIC.Window;
   zone_builders : TIC.Window;
   zone_actions  : TIC.Window;
   viewheight    : TIC.Line_Count;

   c_standard    : TIC.Color_Pair;
   c_slave       : builder_palette;
   c_success     : TIC.Color_Pair;
   c_failure     : TIC.Color_Pair;
   c_ignored     : TIC.Color_Pair;
   c_skipped     : TIC.Color_Pair;
   c_sumlabel    : TIC.Color_Pair;
   c_dashes      : TIC.Color_Pair;
   c_tableheader : TIC.Color_Pair;
   c_elapsed     : TIC.Color_Pair;
   c_origin      : TIC.Color_Pair;
   c_bldphase    : TIC.Color_Pair;
   c_shutdown    : TIC.Color_Pair;

   cursor_vis    : TIC.Cursor_Visibility := TIC.Invisible;

   bright        : constant TIC.Character_Attribute_Set :=
                            (others => False);
   bright_bold   : constant TIC.Character_Attribute_Set :=
                            (Bold_Character => True, others => False);
   dimmed        : constant TIC.Character_Attribute_Set :=
                            (Dim_Character => True, others => False);
   dimmed_bold   : constant TIC.Character_Attribute_Set :=
                            (Bold_Character => True,
                             Dim_Character => True,
                             others => False);

   procedure launch_summary_zone;
   procedure launch_builders_zone (num_builders : builders);
   procedure launch_actions_zone (num_builders : builders);

   function inc (X : TIC.Line_Position; by : Integer) return TIC.Line_Position;

   procedure establish_colors;

end Display;
