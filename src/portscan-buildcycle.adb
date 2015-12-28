--  This file is covered by the Internet Software Consortium (ISC) License
--  Reference: ../License.txt

with Ada.Calendar.Arithmetic;
with Ada.Calendar.Formatting;
with Ada.Direct_IO;
with GNAT.OS_Lib;
with Util.Streams.Pipes;
with Util.Streams.Buffered;
with Util.Processes;

package body PortScan.Buildcycle is

   package ACA renames Ada.Calendar.Arithmetic;
   package ACF renames Ada.Calendar.Formatting;
   package OSL renames GNAT.OS_Lib;
   package STR renames Util.Streams;


   ---------------------
   --  build_package  --
   ---------------------
   function build_package (id : builders; sequence_id : port_id) return Boolean
   is
      R : Boolean;
   begin
      initialize_log (id, sequence_id);
      for phase in phases'Range loop
         case phase is
            when check_sanity  => R := exec_phase_generic (id, "check-sanity");
            when pkg_depends   => R := exec_phase_depends (id, "pkg-depends");
            when fetch_depends => R := exec_phase_depends (id, "fetch-depends");
            when fetch         => R := exec_phase_generic (id, "fetch");
            when checksum      => R := exec_phase_generic (id, "checksum");
            when extract_depends => R := exec_phase_depends (id,
                                                             "extract-depends");
            when extract       => R := exec_phase_generic (id, "checksum");
            when patch_depends => R := exec_phase_depends (id, "patch-depends");
            when patch         => R := exec_phase_generic (id, "patch");
            when build_depends => R := exec_phase_depends (id, "build-depends");
            when lib_depends   => R := exec_phase_depends (id, "lib-depends");
            when configure     => R := exec_phase_generic (id, "configure");
            when build         => R := exec_phase_generic (id, "build");
            when run_depends   => R := exec_phase_depends (id, "run-depends");
            when stage         => R := exec_phase_generic (id, "stage");
            when pkg_package   => R := exec_phase_generic (id, "package");
            when install_mtree =>
               if testing then
                  R := exec_phase_generic (id, "install-mtree");
               end if;
            when install =>
               if testing then
                  R := exec_phase_generic (id, "install");
               end if;
            when deinstall =>
               if testing then
                  R := exec_phase_deinstall (id);
               end if;
            when check_plist =>
               if testing then
                  R := exec_phase_generic (id, "check-plist");
               end if;
         end case;
         exit when R = False;
      end loop;
      finalize_log (id);
      return R;
   end build_package;


   ----------------------
   --  initialize_log  --
   ----------------------
   procedure initialize_log (id : builders; sequence_id : port_id)
   is
      FA    : access TIO.File_Type;
      H_ENV : constant String := "Environment";
      H_OPT : constant String := "Options";
      H_CFG : constant String := "/etc/make.conf";
   begin
      trackers (id).seq_id := sequence_id;
      if sequence_id = port_match_failed then
         raise cycle_log_error
           with "initialization attempted with port_id = 0";
      end if;
      trackers (id).dynlink.Clear;
      trackers (id).head_time := CAL.Clock;
      declare
         log_path : constant String := log_name (sequence_id);
      begin
         if AD.Exists (log_path) then
            AD.Delete_File (log_path);
         end if;
         TIO.Create (File => trackers (id).log_handle,
                     Mode => TIO.Out_File,
                     Name => log_path);
         FA := trackers (id).log_handle'Access;
      exception
         when error : others =>
            raise cycle_log_error
              with "failed to create log " & log_path;
      end;

      TIO.Put_Line (trackers (id).log_handle, "=> Building " &
                      get_catport (all_ports (sequence_id)));
      TIO.Put_Line (FA.all, "Started : " & timestamp (trackers (id).head_time));
      TIO.Put      (FA.all, "Platform: " & JT.USS (uname_mrv));
      TIO.Put_Line (FA.all, LAT.LF & log_section (H_ENV, True));
      TIO.Put      (FA.all, get_environment (id));
      TIO.Put_Line (FA.all, log_section (H_ENV, False) & LAT.LF);
      TIO.Put_Line (FA.all, log_section (H_OPT, True));
      TIO.Put      (FA.all, get_options_configuration (id));
      TIO.Put_Line (FA.all, log_section (H_OPT, False) & LAT.LF);

      dump_port_variables (id);

      TIO.Put_Line (FA.all, log_section (H_CFG, True));
      TIO.Put      (FA.all, dump_make_conf (id));
      TIO.Put_Line (FA.all, log_section (H_CFG, False) & LAT.LF);

   end initialize_log;


   --------------------
   --  finalize_log  --
   --------------------
   procedure finalize_log (id : builders)
   is
     FA : access TIO.File_Type;
   begin
      trackers (id).tail_time := CAL.Clock;
      FA := trackers (id).log_handle'Access;
      TIO.Put_Line (FA.all, "Finished: " & timestamp (trackers (id).tail_time));
      TIO.Put_Line (FA.all, log_duration (start => trackers (id).head_time,
                                          stop  => trackers (id).tail_time));
      TIO.Close (trackers (id).log_handle);
   end finalize_log;


   --------------------
   --  log_duration  --
   --------------------
   function log_duration (start, stop : CAL.Time) return String
   is
      raw : JT.Text := JT.SUS ("Duration:");
      diff_days : ACA.Day_Count;
      diff_secs : Duration;
      leap_secs : ACA.Leap_Seconds_Count;
      use type ACA.Day_Count;
   begin
      ACA.Difference (Left    => stop,
                      Right   => start,
                      Days    => diff_days,
                      Seconds => diff_secs,
                      Leap_Seconds => leap_secs);
      if diff_days > 0 then
         if diff_days = 1 then
            JT.SU.Append (raw, " 1 day and" &
                            ACF.Image (Elapsed_Time => diff_secs));
         else
            JT.SU.Append (raw, diff_days'Img & " days and" &
                            ACF.Image (Elapsed_Time => diff_secs));
         end if;
      else
         JT.SU.Append (raw, " " & ACF.Image (Elapsed_Time => diff_secs));
      end if;
      return JT.USS (raw);
   end log_duration;


   ------------------------
   --  elapsed_HH_MM_SS  --
   ------------------------
   function elapsed_HH_MM_SS (start, stop : CAL.Time) return String
   is
      diff_days : ACA.Day_Count;
      diff_secs : Duration;
      leap_secs : ACA.Leap_Seconds_Count;
      totalsecs : Duration;
      use type ACA.Day_Count;
   begin
      ACA.Difference (Left    => stop,
                      Right   => start,
                      Days    => diff_days,
                      Seconds => diff_secs,
                      Leap_Seconds => leap_secs);
      totalsecs := diff_secs + (Duration (diff_days) * 3600 * 24);
      return ACF.Image (Elapsed_Time => diff_secs);
   end elapsed_HH_MM_SS;


   -------------------
   --  elapsed_now  --
   -------------------
   function elapsed_now return String is
   begin
      return elapsed_HH_MM_SS (start => start_time, stop => CAL.Clock);
   end elapsed_now;


   -----------------
   --  timestamp  --
   -----------------
   function timestamp (hack : CAL.Time) return String
   is
      function MON   (num : CAL.Month_Number) return String;
      function WKDAY (day : ACF.Day_Name) return String;

      function MON (num : CAL.Month_Number) return String is
      begin
         case num is
            when 1 => return "JAN";
            when 2 => return "FEB";
            when 3 => return "MAR";
            when 4 => return "APR";
            when 5 => return "MAY";
            when 6 => return "JUN";
            when 7 => return "JUL";
            when 8 => return "AUG";
            when 9 => return "SEP";
            when 10 => return "OCT";
            when 11 => return "NOV";
            when 12 => return "DEC";
         end case;
      end MON;
      function WKDAY (day : ACF.Day_Name) return String is
      begin
         case day is
            when ACF.Monday    => return "Monday";
            when ACF.Tuesday   => return "Tuesday";
            when ACF.Wednesday => return "Wednesday";
            when ACF.Thursday  => return "Thursday";
            when ACF.Friday    => return "Friday";
            when ACF.Saturday  => return "Saturday";
            when ACF.Sunday    => return "Sunday";
         end case;
      end WKDAY;
   begin
      return WKDAY (ACF.Day_Of_Week (hack)) & "," & CAL.Day (hack)'Img & " " &
        MON (CAL.Month (hack)) & CAL.Year (hack)'Img & " at" &
        ACF.Image (hack)(11 .. 19) & " UTC";
   end timestamp;


   -----------------------------
   -- generic_system_command  --
   -----------------------------
   function generic_system_command (command : String) return JT.Text
   is
      pipe    : aliased STR.Pipes.Pipe_Stream;
      buffer  : STR.Buffered.Buffered_Stream;
      content : JT.Text;
      status  : Integer;
   begin
      pipe.Open (Command => command, Mode => Util.Processes.READ_ALL);
      buffer.Initialize (Output => null,
                         Input  => pipe'Unchecked_Access,
                         Size   => 4096);
      buffer.Read (Into => content);
      pipe.Close;
      status := pipe.Get_Exit_Status;
      if status /= 0 then
         raise cycle_cmd_error with "cmd: " & command &
           " (return code =" & status'Img & ")";
      end if;
      return content;
   end generic_system_command;


   ---------------------
   --  set_uname_mrv  --
   ---------------------
   procedure set_uname_mrv
   is
      command : constant String := "/usr/bin/uname -mrv";
   begin
      uname_mrv := generic_system_command (command);
   end set_uname_mrv;


   ----------------
   --  get_root  --
   ----------------
   function get_root (id : builders) return String
   is
      id_image     : constant String := Integer (id)'Img;
      suffix       : String := "/SL00";
   begin
      if id < 10 then
         suffix (5) := id_image (2);
      else
         suffix (4 .. 5) := id_image (2 .. 3);
      end if;
      return JT.USS (PM.configuration.dir_buildbase) & suffix;
   end get_root;


   -----------------------
   --  get_environment  --
   -----------------------
   function get_environment (id : builders) return String
   is
      root    : constant String := get_root (id);
      command : constant String := chroot & root & " /usr/bin/env";
   begin
      return JT.USS (generic_system_command (command));
   end get_environment;


   ---------------------------------
   --  get_options_configuration  --
   ---------------------------------
   function get_options_configuration (id : builders) return String
   is
      root    : constant String := get_root (id);
      command : constant String := chroot & root &
        " /usr/bin/make -C /xports/" &
        get_catport (all_ports (trackers (id).seq_id)) &
        " showconfig";
   begin
      return JT.USS (generic_system_command (command));
   end get_options_configuration;


   ------------------------
   --  split_collection  --
   ------------------------
   function split_collection (line : JT.Text; title : String) return String
   is
      meat    : JT.Text;
      waiting : Boolean := True;
      quoted  : Boolean := False;
      keepit  : Boolean;
      counter : Natural := 0;
      meatlen : Natural := 0;
      linelen : Natural := JT.SU.Length (line);
      onechar : String (1 .. 1);
      meatstr : String (1 .. linelen);
   begin
      loop
         counter := counter + 1;
         exit when counter > linelen;
         keepit  := True;
         onechar := JT.SU.Slice (Source => line,
                                 Low    => counter,
                                 High   => counter);
         if onechar (1) = LAT.Space then
            if waiting then
               keepit := False;
            else
               if not quoted then
                  --  name-pair ended, reset
                  waiting := True;
                  quoted  := False;
                  onechar (1) := LAT.LF;
               end if;
            end if;
         else
            waiting := False;
            if onechar (1) = LAT.Quotation then
               quoted := not quoted;
            end if;
         end if;
         if keepit then
            meatlen := meatlen + 1;
            meatstr (meatlen) := onechar (1);
         end if;
      end loop;
      return log_section (title, True) & LAT.LF &
        meatstr (1 .. meatlen) & LAT.LF &
        log_section (title, False) & LAT.LF;
   end split_collection;


   ---------------------------
   --  dump_port_variables  --
   ---------------------------
   procedure dump_port_variables (id : builders)
   is
      root    : constant String := get_root (id);
      command : constant String := chroot & root &
        " /usr/bin/make -C /xports/" &
        get_catport (all_ports (trackers (id).seq_id)) &
        " -VCONFIGURE_ENV -VCONFIGURE_ARGS -VMAKE_ENV -VMAKE_ARGS" &
        " -VPLIST_SUB -VSUB_LIST";
      LA      : access TIO.File_Type := trackers (id).log_handle'Access;
      content : JT.Text;
      topline : JT.Text;
      type result_range is range 1 .. 6;
   begin
      content := generic_system_command (command);
      for k in result_range loop
         JT.nextline (lineblock => content, firstline => topline);
         case k is
            when 1 => TIO.Put_Line
                 (LA.all, split_collection (topline, "CONFIGURE_ENV"));
            when 2 => TIO.Put_Line
                 (LA.all, split_collection (topline, "CONFIGURE_ARGS"));
            when 3 => TIO.Put_Line
                 (LA.all, split_collection (topline, "MAKE_ENV"));
            when 4 => TIO.Put_Line
                 (LA.all, split_collection (topline, "MAKE_ARGS"));
            when 5 => TIO.Put_Line
                 (LA.all, split_collection (topline, "PLIST_SUB"));
            when 6 => TIO.Put_Line
                 (LA.all, split_collection (topline, "SUB_LIST"));
         end case;
      end loop;
   end dump_port_variables;


   ----------------
   --  log_name  --
   ----------------
   function log_name (sid : port_id) return String
   is
      catport : constant String := get_catport (all_ports (sid));
   begin
      return JT.USS (PM.configuration.dir_logs) & "/" &
        JT.part_1 (catport) & "___" & JT.part_2 (catport) & ".log";
   end log_name;


   -----------------
   --  dump_file  --
   -----------------
   function  dump_file (filename : String) return String
   is
      File_Size : Natural := Natural (AD.Size (filename));

      subtype File_String    is String (1 .. File_Size);
      package File_String_IO is new Ada.Direct_IO (File_String);

      File     : File_String_IO.File_Type;
      Contents : File_String;
   begin
      File_String_IO.Open  (File, Mode => File_String_IO.In_File,
                            Name => filename);
      File_String_IO.Read  (File, Item => Contents);
      File_String_IO.Close (File);
      return String (Contents);
   end dump_file;


   ----------------------
   --  dump_make_conf  --
   ----------------------
   function dump_make_conf (id : builders) return String
   is
      root     : constant String := get_root (id);
      filename : constant String := root & "/etc/make.conf";
   begin
      return dump_file (filename);
   end dump_make_conf;


   ------------------
   --  initialize  --
   ------------------
   procedure initialize (test_mode : Boolean)
   is
      logdir : constant String := JT.USS (PM.configuration.dir_logs);
   begin
      set_uname_mrv;
      testing := test_mode;
      if not AD.Exists (logdir) then
         AD.Create_Path (New_Directory => logdir);
      end if;
   exception
         when error : others =>
            raise cycle_log_error
              with "failed to create " & logdir;
   end initialize;


   -------------------
   --  log_section  --
   -------------------
   function log_section (title : String; header : Boolean) return String
   is
      first_part : constant String := "[ " & title;
   begin
      if header then
         return first_part & " HEAD ]";
      else
         return first_part & " TAIL ]";
      end if;
   end log_section;


   ---------------------
   --  log_phase_end  --
   ---------------------
   procedure log_phase_end (id : builders)
   is
      dash : constant String := "=========================";
   begin
      TIO.Put_Line (trackers (id).log_handle, dash & dash & dash & LAT.LF);
   end log_phase_end;


   -----------------------
   --  log_phase_begin  --
   -----------------------
   procedure log_phase_begin (phase : String; id : builders)
   is
      plast  : constant Natural := 10 + phase'Length;
      dash   : constant String := "========================";
      middle :          String := "< phase :                 >";
   begin
      middle (11 .. plast) := phase;
      TIO.Put_Line (trackers (id).log_handle, dash & middle & dash);
   end log_phase_begin;


   --------------------------
   --  exec_phase_generic  --
   --------------------------
   function exec_phase_generic (id : builders; phase : String) return Boolean is
   begin
      if testing then
         return exec_phase (id => id, phase => phase,
                            phaseenv => "DEVELOPER=1");
      else
         return exec_phase (id => id, phase => phase);
      end if;
   end exec_phase_generic;


   --------------------------
   --  exec_phase_depends  --
   --------------------------
   function exec_phase_depends (id : builders; phase : String) return Boolean
   is
      phaseenv : String := "USE_PACKAGE_DEPENDS_ONLY=1";
   begin
      return exec_phase (id => id, phase => phase, phaseenv => phaseenv,
                         depends_phase => True);
   end exec_phase_depends;


   ----------------------------
   --  exec_phase_deinstall  --
   ----------------------------
   function exec_phase_deinstall (id : builders) return Boolean
   is
      phase : constant String := "deinstall";
   begin
      --  This is only run during "testing" so assume that.
      log_phase_begin (phase, id);
      log_linked_libraries (id);
      return exec_phase (id => id, phase => phase, phaseenv => "DEVELOPER=1",
                         skip_header => True);
   end exec_phase_deinstall;


   -----------------------
   --  generic_execute  --
   -----------------------
   function generic_execute (id : builders; command : String) return Boolean
   is
      Args        : OSL.Argument_List_Access;
      Exit_Status : Integer;
      FD          : OSL.File_Descriptor;
   begin
      FD := OSL.Open_Append (Name  => log_name (trackers (id).seq_id),
                             Fmode => OSL.Text);

      Args := OSL.Argument_String_To_List (command);
      OSL.Spawn (Program_Name => Args (Args'First).all,
                 Args         => Args (Args'First + 1 .. Args'Last),
                 Return_Code  => Exit_Status,
                 Output_File_Descriptor => FD);
      OSL.Free (Args);

      OSL.Close (FD);
      return Exit_Status = 0;
   end generic_execute;


   ------------------
   --  exec_phase  --
   ------------------
   function exec_phase (id : builders; phase : String; phaseenv : String := "";
                        depends_phase : Boolean := False;
                        skip_header   : Boolean := False)
                        return Boolean
   is
      root       : constant String := get_root (id);
      port_flags : String := " NO_DEPENDS=yes ";
      dev_flags  : String := " DEVELOPER_MODE=yes ";
      pid        : port_id := trackers (id).seq_id;
      catport    : constant String := get_catport (all_ports (pid));
      result     : Boolean;
   begin
      if testing or else depends_phase
      then
         port_flags := (others => LAT.Space);
      else
         dev_flags := (others => LAT.Space);
      end if;

      --  Nasty, we have to switch open and close the log file for each
      --  phase because we have to switch between File_Type and File
      --  Descriptors.  I can't find a safe way to get the File Descriptor
      --  out of the File type.

      if not skip_header then
         log_phase_begin (phase, id);
      end if;
      TIO.Close (trackers (id).log_handle);

      declare
           command : constant String := chroot & root &
           " /usr/bin/env " & phaseenv & dev_flags & port_flags &
           "/usr/bin/make -C /xports/" & catport & " " & phase;
      begin
         result := generic_execute (id, command);
      end;

      --  Reopen the log.  I guess we can leave off the exception check
      --  since it's been passing before

      TIO.Open (File => trackers (id).log_handle,
                Mode => TIO.Append_File,
                Name => log_name (trackers (id).seq_id));
      log_phase_end (id);

      return result;
   end exec_phase;


   --------------------
   --  install_pkg8  --
   --------------------
   function install_pkg8 (id : builders) return Boolean
   is
      root    : constant String := get_root (id);
      taropts : constant String := "-C / */pkg-static";
      command : constant String := chroot & root &
        " /usr/bin/tar -xf /packages/Latest/pkg.txz " & taropts;
   begin
      return generic_execute (id, command);
   end install_pkg8;


   ------------------------
   --  build_repository  --
   ------------------------
   function build_repository (id : builders) return Boolean
   is
      root    : constant String := get_root (id);
      command : constant String := chroot & root & " " &
        host_localbase & "/sbin/pkg-static repo /packages";
   begin
      if not install_pkg8 (id) then
         TIO.Put_Line ("Failed to install pkg-static in builder" & id'Img);
         return False;
      end if;
      return generic_execute (id, command);
   end build_repository;


   --------------------------
   --  dynamically_linked  --
   --------------------------
   function dynamically_linked (base, filename : String) return Boolean
   is
      command : String := chroot & base & " /usr/bin/file -b " &
        "-e ascii -e encoding -e tar -e compress " & filename;
      comres  : JT.Text;
   begin
      comres := generic_system_command (command);
      return JT.contains (comres, "dynamically linked");
   end dynamically_linked;


   ----------------------------
   --  log_linked_libraries  --
   ----------------------------
   procedure stack_linked_libraries (id : builders; base, filename : String)
   is
      command : String := chroot & base & " /usr/bin/objdump -p " & filename;
      comres  : JT.Text;
      topline : JT.Text;
      crlen1  : Natural;
      crlen2  : Natural;
   begin
      comres := generic_system_command (command);
      crlen1 := JT.SU.Length (comres);
      loop
         JT.nextline (lineblock => comres, firstline => topline);
         crlen2 := JT.SU.Length (comres);
         exit when crlen1 = crlen2;
         crlen1 := crlen2;
         if not JT.IsBlank (topline) then
            if JT.contains (topline, "NEEDED") then
               if not trackers (id).dynlink.Contains (topline) then
                  trackers (id).dynlink.Append (topline);
               end if;
            end if;
         end if;
      end loop;
   exception
         --  the command result was not zero, so it was an expected format
         --  or static file.  Just skip it.  (Should never happen)
      when bad_result : others => null;
   end stack_linked_libraries;


   ----------------------------
   --  log_linked_libraries  --
   ----------------------------
   procedure log_linked_libraries (id : builders)
   is
      procedure log_dump (cursor : string_crate.Cursor);

      comres  : JT.Text;
      topline : JT.Text;
      crlen1  : Natural;
      crlen2  : Natural;
      pkgfile : constant String := JT.USS
                         (all_ports (trackers (id).seq_id).package_name);
      pkgname : constant String := pkgfile (1 .. pkgfile'Last - 4);
      root    : constant String := get_root (id);
      command : constant String := chroot & root & " " &
        host_localbase & "/sbin/pkg query %Fp " & pkgname;

      procedure log_dump (cursor : string_crate.Cursor) is
      begin
         TIO.Put_Line (trackers (id).log_handle,
                       JT.USS (string_crate.Element (Position => cursor)));
      end log_dump;
   begin
      TIO.Put_Line (trackers (id).log_handle,
                    "=> Checking shared library dependencies");
      comres := generic_system_command (command);
      crlen1 := JT.SU.Length (comres);
      loop
         JT.nextline (lineblock => comres, firstline => topline);
         crlen2 := JT.SU.Length (comres);
         exit when crlen1 = crlen2;
         crlen1 := crlen2;
         if dynamically_linked (root, JT.USS (topline)) then
            stack_linked_libraries (id, root, JT.USS (topline));
         end if;
      end loop;
      trackers (id).dynlink.Iterate (log_dump'Access);
   end log_linked_libraries;


   ------------------------
   --  external_command  --
   ------------------------
   function external_command (command : String) return Boolean
   is
      Args        : OSL.Argument_List_Access;
      Exit_Status : Integer;
   begin
      Args := OSL.Argument_String_To_List (command);
      Exit_Status := OSL.Spawn (Program_Name => Args (Args'First).all,
                                Args => Args (Args'First + 1 .. Args'Last));
      OSL.Free (Args);
      return Exit_Status = 0;
   end external_command;

end PortScan.Buildcycle;
