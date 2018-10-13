open Test_helpers

let with_file_for_reading ?(to_fail = false) f =
  let flags =
    if not to_fail then
      Luv.File.Open_flag.rdonly
    else
      Luv.File.Open_flag.wronly
  in

  let file =
    Luv.File.(Sync.open_ "file.ml" flags)
    |> check_success_result "open_"
  in

  f file;

  Luv.File.Sync.close file
  |> check_success "close"

let with_file_for_writing f =
  let filename = "write_test_output" in

  let file =
    Luv.File.(Sync.open_ filename Open_flag.(list [wronly; creat; trunc]))
    |> check_success_result "open_";
  in

  f file;

  Luv.File.Sync.close file
  |> check_success "close";

  let channel = Pervasives.open_in filename in
  let content = Pervasives.input_line channel in
  Pervasives.close_in channel;

  Alcotest.(check string) "content" "ope" content

let with_dummy_file f =
  let filename = "test_dummy" in

  Pervasives.open_out filename
  |> Pervasives.close_out;

  f filename;

  if Sys.file_exists filename then
    Sys.remove filename

let with_directory f =
  let directory = "dir" in
  let file_1 = "dir/foo" in
  let file_2 = "dir/bar" in

  Unix.mkdir "dir" 0o755;
  Pervasives.open_out file_1 |> Pervasives.close_out;
  Pervasives.open_out file_2 |> Pervasives.close_out;

  f directory;

  Sys.remove file_1;
  Sys.remove file_2;
  Unix.rmdir directory

let call_scandir_next_repeatedly scan =
  let rec repeat entry_accumulator =
    match Luv.File.Directory_scan.next scan with
    | Some entry ->
      repeat (entry::entry_accumulator)
    | None ->
      Luv.File.Directory_scan.stop scan;
      entry_accumulator
  in
  repeat []

let tests = [
  "file", [
    "open, read, close: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.(Async.open_ "file.ml" Open_flag.rdonly) begin fun result ->
        let file = check_success_result "file" result in

        let buffer = Luv.Bigstring.create 4 in
        Bigarray.Array1.fill buffer '\000';

        Luv.File.Async.read file [buffer] begin fun result ->
          let byte_count = check_success_result "read result" result in
          Alcotest.(check int)
            "byte count" 4 (Unsigned.Size_t.to_int byte_count);
          Alcotest.(check char) "byte 0" 'o' (Bigarray.Array1.get buffer 0);
          Alcotest.(check char) "byte 1" 'p' (Bigarray.Array1.get buffer 1);
          Alcotest.(check char) "byte 2" 'e' (Bigarray.Array1.get buffer 2);
          Alcotest.(check char) "byte 3" 'n' (Bigarray.Array1.get buffer 3);

          Luv.File.Async.close file begin fun result ->
            check_success "close result" result;
            finished := true
          end
        end
      end;

      run ();

      Alcotest.(check bool) "finished" true !finished
    end;

    "open, read, close: sync", `Quick, begin fun () ->
      let file =
        Luv.File.(Sync.open_ "file.ml" Open_flag.rdonly)
        |> check_success_result "open_"
      in

      let buffer = Luv.Bigstring.create 4 in
      Bigarray.Array1.fill buffer '\000';

      let byte_count =
        Luv.File.Sync.read file [buffer]
        |> check_success_result "read"
      in

      Alcotest.(check int) "byte count" 4 (Unsigned.Size_t.to_int byte_count);
      Alcotest.(check char) "byte 0" 'o' (Bigarray.Array1.get buffer 0);
      Alcotest.(check char) "byte 1" 'p' (Bigarray.Array1.get buffer 1);
      Alcotest.(check char) "byte 2" 'e' (Bigarray.Array1.get buffer 2);
      Alcotest.(check char) "byte 3" 'n' (Bigarray.Array1.get buffer 3);

      Luv.File.Sync.close file
      |> check_success "close"
    end;

    "open nonexistent: async", `Quick, begin fun () ->
      let result = ref (Result.Error Luv.Error.success) in

      Luv.File.(Async.open_
          "non_existent_file" Open_flag.rdonly) begin fun result' ->

        result := result'
      end;

      run ();
      check_error_result "result" Luv.Error.enoent !result
    end;

    "open nonexistent: sync", `Quick, begin fun () ->
      Luv.File.(Sync.open_ "non_existent_file" Open_flag.rdonly)
      |> check_error_result "open_" Luv.Error.enoent
    end;

    "open, close memory leak: async", `Quick, begin fun () ->
      no_memory_leak begin fun _ ->
        let finished = ref false in

        Luv.File.(Async.open_ "file.ml" Open_flag.rdonly) begin fun result ->
          let file = check_success_result "file" result in
          Luv.File.Async.close file begin fun _ ->
            finished := true
          end
        end;

        run ();
        Alcotest.(check bool) "finished" true !finished
      end
    end;

    "open, close memory leak: sync", `Quick, begin fun () ->
      no_memory_leak begin fun _ ->
        let file =
          Luv.File.(Sync.open_ "file.ml" Open_flag.rdonly)
          |> check_success_result "open_"
        in

        Luv.File.Sync.close file
        |> check_success "close"
      end
    end;

    "open failure leak: async", `Quick, begin fun () ->
      no_memory_leak begin fun _ ->
        Luv.File.(Async.open_ "non_existent_file" Open_flag.rdonly)
            begin fun result ->

          check_error_result "result" Luv.Error.enoent result
        end;

        run ()
      end
    end;

    "open failure leak: sync", `Quick, begin fun () ->
      no_memory_leak begin fun _ ->
        Luv.File.(Sync.open_ "non_existent_file" Open_flag.rdonly)
        |> check_error_result "open_" Luv.Error.enoent;
      end
    end;

    "open gc", `Quick, begin fun () ->
      Gc.full_major ();

      let called = ref false in

      Luv.File.(Async.open_ "non_existent_file" Open_flag.rdonly)
          begin fun _result ->

        called := true
      end;

      Gc.full_major ();

      run ();
      Alcotest.(check bool) "called" true !called
    end;

    "read failure: async", `Quick, begin fun () ->
      with_file_for_reading ~to_fail:true begin fun file ->
        let buffer = Luv.Bigstring.create 1 in

        Luv.File.Async.read file [buffer] begin fun result ->
          check_error_result "byte_count" Luv.Error.ebadf result
        end;

        run ()
      end
    end;

    "read failure: sync", `Quick, begin fun () ->
      with_file_for_reading ~to_fail:true begin fun file ->
        let buffer = Luv.Bigstring.create 1 in

        Luv.File.Sync.read file [buffer]
        |> check_error_result "read" Luv.Error.ebadf
      end
    end;

    "read leak: async", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        let buffer = Luv.Bigstring.create 1 in

        no_memory_leak begin fun _ ->
          let finished = ref false in

          Luv.File.Async.read file [buffer] begin fun _ ->
            finished := true
          end;

          run ();
          Alcotest.(check bool) "finished" true !finished
        end
      end
    end;

    "read leak: sync", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        let buffer = Luv.Bigstring.create 1 in

        no_memory_leak begin fun _ ->
          Luv.File.Sync.read file [buffer]
          |> check_success_result "read"
          |> ignore;
        end
      end
    end;

    "read sync failure leak", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        no_memory_leak begin fun _ ->
          Luv.File.Async.read file [] ignore;
          run ()
        end
      end
    end;

    "read gc", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        Gc.full_major ();

        let called = ref false in
        let buffer = Luv.Bigstring.create 1 in
        Bigarray.Array1.fill buffer '\000';

        let finalized = ref false in
        Gc.finalise (fun _ -> finalized := true) buffer;

        Luv.File.Async.read file [buffer] begin fun _ ->
          called := true
        end;

        Gc.full_major ();
        Alcotest.(check bool) "finalized (1)" false !finalized;

        run ();
        Alcotest.(check bool) "called" true !called;

        Gc.full_major ();
        Alcotest.(check bool) "finalized (2)" true !finalized
      end
    end;

    "write: async", `Quick, begin fun () ->
      with_file_for_writing begin fun file ->
        let buffer = Luv.Bigstring.create 3 in
        Bigarray.Array1.set buffer 0 'o';
        Bigarray.Array1.set buffer 1 'p';
        Bigarray.Array1.set buffer 2 'e';

        Luv.File.Async.write file [buffer] begin fun result ->
          let byte_count = check_success_result "write result" result in
          Alcotest.(check int)
            "byte count" 3 (Unsigned.Size_t.to_int byte_count)
        end;

        run ()
      end
    end;

    "write: sync", `Quick, begin fun () ->
      with_file_for_writing begin fun file ->
        let buffer = Luv.Bigstring.create 3 in
        Bigarray.Array1.set buffer 0 'o';
        Bigarray.Array1.set buffer 1 'p';
        Bigarray.Array1.set buffer 2 'e';

        Luv.File.Sync.write file [buffer]
        |> check_success_result "write"
        |> ignore
      end
    end;

    "unlink: async", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        Alcotest.(check bool) "exists" true (Sys.file_exists path);

        Luv.File.Async.unlink path begin fun result ->
          check_success "result" result
        end;

        run ();
        Alcotest.(check bool) "does not exist" false (Sys.file_exists path)
      end
    end;

    "unlink: sync", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        Alcotest.(check bool) "exists" true (Sys.file_exists path);

        Luv.File.Sync.unlink path
        |> check_success "unlink";

        Alcotest.(check bool) "does not exist" false (Sys.file_exists path)
      end
    end;

    "unlink failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.unlink "non_existent_file" begin fun result ->
        check_error_code "result" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "unlink failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.unlink "non_existent_file"
      |> check_error_code "unlink" Luv.Error.enoent
    end;

    "mkdir, rmdir: async", `Quick, begin fun () ->
      let finished = ref false in
      let directory = "dummy_directory" in

      Luv.File.Async.mkdir directory begin fun result ->
        check_success "mkdir result" result;
        Alcotest.(check bool) "exists" true (Sys.file_exists directory);

        Luv.File.Async.rmdir directory begin fun result ->
          check_success "rmdir result" result;
          Alcotest.(check bool)
            "does not exist" false (Sys.file_exists directory);

          finished := true
        end
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "mkdir, rmdir: sync", `Quick, begin fun () ->
      let directory = "dummy_directory" in

      Luv.File.Sync.mkdir directory
      |> check_success "mkdir";

      Alcotest.(check bool) "exists" true (Sys.file_exists directory);

      Luv.File.Sync.rmdir directory
      |> check_success "rmdir";

      Alcotest.(check bool) "does not exist" false (Sys.file_exists directory)
    end;

    "mkdir failure: async", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        let finished = ref false in

        Luv.File.Async.mkdir path begin fun result ->
          check_error_code "mkdir result" Luv.Error.eexist result;
          finished := true
        end;

        run ();
        Alcotest.(check bool) "finished" true !finished
      end
    end;

    "mkdir failure: sync", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        Luv.File.Sync.mkdir path
        |> check_error_code "mkdir" Luv.Error.eexist
      end
    end;

    "rmdir failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.rmdir "non_existent_file" begin fun result ->
        check_error_code "rmdir result" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "rmdir failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.rmdir "non_existent_file"
      |> check_error_code "rmdir" Luv.Error.enoent
    end;

    "mkdtemp: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.mkdtemp "fooXXXXXX" begin fun result ->
        let path = check_success_result "mkdtemp result" result in

        Luv.File.Async.rmdir path begin fun result ->
          check_success "rmdir result" result;
          finished := true
        end
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "mkdtemp: sync", `Quick, begin fun () ->
      let path =
        Luv.File.Sync.mkdtemp "fooXXXXXX"
        |> check_success_result "mkdtemp"
      in

      Luv.File.Sync.rmdir path
      |> check_success "rmdir"
    end;

    "mkdtemp failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.mkdtemp "foo" begin fun result ->
        check_error_result "mkdtemp result" Luv.Error.einval result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "mkdtemp failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.mkdtemp "foo"
      |> check_error_result "mkdtemp result" Luv.Error.einval
    end;

    "scandir: async", `Quick, begin fun () ->
      with_directory begin fun directory ->
        let entries = ref [] in

        Luv.File.Async.scandir directory begin fun result ->
          entries :=
            check_success_result "scandir" result
            |> call_scandir_next_repeatedly
        end;

        run ();
        check_directory_entries "scandir_next" ["foo"; "bar"] !entries
      end
    end;

    "scandir: sync", `Quick, begin fun () ->
      with_directory begin fun directory ->
        Luv.File.Sync.scandir directory
        |> check_success_result "scandir"
        |> call_scandir_next_repeatedly
        |> check_directory_entries "scandir_next" ["foo"; "bar"]
      end
    end;

    "scandir failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.scandir "non_existent_directory" begin fun result ->
        check_error_result "scandir" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "scandir failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.scandir "non_existent_directory"
      |> check_error_result "scandir" Luv.Error.enoent
    end;

    "stat: async", `Quick, begin fun () ->
      let size = ref 0 in

      Luv.File.Async.stat "file.ml" begin fun result ->
        check_success_result "stat" result
        |> fun stat -> size := Unsigned.UInt64.to_int Luv.File.Stat.(stat.size)
      end;

      run ();
      Alcotest.(check int) "size" Unix.((stat "file.ml").st_size) !size
    end;

    "stat: sync", `Quick, begin fun () ->
      Luv.File.Sync.stat "file.ml"
      |> check_success_result "stat"
      |> fun stat -> Luv.File.Stat.(stat.size)
      |> Unsigned.UInt64.to_int
      |> Alcotest.(check int) "size" Unix.((stat "file.ml").st_size)
    end;

    "stat failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.stat "non_existent_file" begin fun result ->
        check_error_result "stat" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "stat failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.stat "non_existent_file"
      |> check_error_result "stat" Luv.Error.enoent
    end;

    "lstat: async", `Quick, begin fun () ->
      let size = ref 0 in

      Luv.File.Async.lstat "file.ml" begin fun result ->
        check_success_result "lstat" result
        |> fun stat -> size := Unsigned.UInt64.to_int Luv.File.Stat.(stat.size)
      end;

      run ();
      Alcotest.(check int) "size" Unix.((lstat "file.ml").st_size) !size
    end;

    "lstat: sync", `Quick, begin fun () ->
      Luv.File.Sync.lstat "file.ml"
      |> check_success_result "lstat"
      |> fun stat -> Luv.File.Stat.(stat.size)
      |> Unsigned.UInt64.to_int
      |> Alcotest.(check int) "size" Unix.((lstat "file.ml").st_size)
    end;

    "lstat failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.lstat "non_existent_file" begin fun result ->
        check_error_result "lstat" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "lstat failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.lstat "non_existent_file"
      |> check_error_result "lstat" Luv.Error.enoent
    end;

    "fstat: async", `Quick, begin fun () ->
      let size = ref 0 in

      with_file_for_reading begin fun file ->
        Luv.File.Async.fstat file begin fun result ->
          check_success_result "fstat" result
          |> fun stat ->
            size := Unsigned.UInt64.to_int Luv.File.Stat.(stat.size)
        end;

        run ()
      end;

      Alcotest.(check int) "size" Unix.((stat "file.ml").st_size) !size
    end;

    "fstat: sync", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        Luv.File.Sync.fstat file
        |> check_success_result "fstat"
        |> fun stat -> Luv.File.Stat.(stat.size)
        |> Unsigned.UInt64.to_int
        |> Alcotest.(check int) "size" Unix.((stat "file.ml").st_size)
      end
    end;

    "rename: async", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        let to_ = path ^ ".renamed" in

        Alcotest.(check bool) "original at start" true (Sys.file_exists path);
        Alcotest.(check bool) "new at start" false (Sys.file_exists to_);

        Luv.File.Async.rename ~from:path ~to_ (check_success "rename");
        run ();

        Alcotest.(check bool) "original at end" false (Sys.file_exists path);
        Alcotest.(check bool) "new at end" true (Sys.file_exists to_);

        Sys.remove to_
      end
    end;

    "rename: sync", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        let to_ = path ^ ".renamed" in

        Alcotest.(check bool) "original at start" true (Sys.file_exists path);
        Alcotest.(check bool) "new at start" false (Sys.file_exists to_);

        Luv.File.Sync.rename ~from:path ~to_
        |> check_success "rename";

        Alcotest.(check bool) "original at end" false (Sys.file_exists path);
        Alcotest.(check bool) "new at end" true (Sys.file_exists to_);

        Sys.remove to_
      end
    end;

    "rename failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.Async.rename ~from:"non_existent_file" ~to_:"foo"
          begin fun result ->

        check_error_code "rename" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "rename failure: sync", `Quick, begin fun () ->
      Luv.File.Sync.rename ~from:"non_existent_file" ~to_:"foo"
      |> check_error_code "rename" Luv.Error.enoent
    end;

    "ftruncate: async", `Quick, begin fun () ->
      let buffer = Luv.Bigstring.create 4 in
      Bigarray.Array1.set buffer 0 'o';
      Bigarray.Array1.set buffer 1 'p';
      Bigarray.Array1.set buffer 2 'e';
      Bigarray.Array1.set buffer 3 'n';

      with_file_for_writing begin fun file ->
        Luv.File.Sync.write file [buffer]
        |> check_success_result "write"
        |> Unsigned.Size_t.to_int
        |> Alcotest.(check int) "bytes written" 4;

        Luv.File.Async.ftruncate file 3L (check_success "ftruncate");
        run ()
      end
    end;

    "ftruncate: sync", `Quick, begin fun () ->
      let buffer = Luv.Bigstring.create 4 in
      Bigarray.Array1.set buffer 0 'o';
      Bigarray.Array1.set buffer 1 'p';
      Bigarray.Array1.set buffer 2 'e';
      Bigarray.Array1.set buffer 3 'n';

      with_file_for_writing begin fun file ->
        Luv.File.Sync.write file [buffer]
        |> check_success_result "write"
        |> Unsigned.Size_t.to_int
        |> Alcotest.(check int) "bytes written" 4;

        Luv.File.Sync.ftruncate file 3L
        |> check_success "ftruncate"
      end
    end;

    "ftruncate failure: async", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        let finished = ref false in

        Luv.File.Async.ftruncate file 0L begin fun result ->
          check_error_code "ftruncate" Luv.Error.einval result;
          finished := true
        end;

        run ();
        Alcotest.(check bool) "finished" true !finished
      end
    end;

    "ftruncate failure: sync", `Quick, begin fun () ->
      with_file_for_reading begin fun file ->
        Luv.File.Sync.ftruncate file 0L
        |> check_error_code "ftruncate" Luv.Error.einval
      end
    end;

    "copyfile: async", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        let to_ = path ^ ".copy" in

        Alcotest.(check bool) "original at start" true (Sys.file_exists path);
        Alcotest.(check bool) "new at start" false (Sys.file_exists to_);

        Luv.File.(Async.copyfile
          ~from:path ~to_ Copy_flag.none) (check_success "copyfile");
        run ();

        Alcotest.(check bool) "original at end" true (Sys.file_exists path);
        Alcotest.(check bool) "new at end" true (Sys.file_exists to_);

        Sys.remove to_
      end
    end;

    "copyfile: sync", `Quick, begin fun () ->
      with_dummy_file begin fun path ->
        let to_ = path ^ ".copy" in

        Alcotest.(check bool) "original at start" true (Sys.file_exists path);
        Alcotest.(check bool) "new at start" false (Sys.file_exists to_);

        Luv.File.(Sync.copyfile ~from:path ~to_ Copy_flag.none)
        |> check_success "copyfile";

        Alcotest.(check bool) "original at end" true (Sys.file_exists path);
        Alcotest.(check bool) "new at end" true (Sys.file_exists to_);

        Sys.remove to_
      end
    end;

    "copyfile failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.(Async.copyfile
          ~from:"non_existent_file" ~to_:"foo" Copy_flag.none)
          begin fun result ->

        check_error_code "copyfile" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "copyfile failure: sync", `Quick, begin fun () ->
      Luv.File.(Sync.copyfile
        ~from:"non_existent_file" ~to_:"foo" Copy_flag.none)
      |> check_error_code "copyfile" Luv.Error.enoent
    end;

    "sendfile: async", `Quick, begin fun () ->
      with_file_for_reading begin fun from ->
        with_file_for_writing begin fun to_ ->
          Luv.File.Async.sendfile
              ~to_ ~from ~offset:0L (Unsigned.Size_t.of_int 3)
              begin fun result ->

            check_success_result "sendfile" result
            |> Unsigned.Size_t.to_int
            |> Alcotest.(check int) "byte count" 3
          end;

          run ()
        end
      end
    end;

    "sendfile: sync", `Quick, begin fun () ->
      with_file_for_reading begin fun from ->
        with_file_for_writing begin fun to_ ->
          Luv.File.Sync.sendfile
            ~to_ ~from ~offset:0L (Unsigned.Size_t.of_int 3)
          |> check_success_result "sendfile"
          |> Unsigned.Size_t.to_int
          |> Alcotest.(check int) "byte count" 3
        end
      end
    end;

    "access: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.(Async.access "file.ml" Access_flag.r) begin fun result ->
        check_success "access" result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "access: sync", `Quick, begin fun () ->
      Luv.File.(Sync.access "file.ml" Access_flag.r)
      |> check_success "access"
    end;

    "access failure: async", `Quick, begin fun () ->
      let finished = ref false in

      Luv.File.(Async.access "non_existent_file" Access_flag.r)
          begin fun result ->

        check_error_code "access" Luv.Error.enoent result;
        finished := true
      end;

      run ();
      Alcotest.(check bool) "finished" true !finished
    end;

    "access failure: sync", `Quick, begin fun () ->
      Luv.File.(Sync.access "non_existent_file" Access_flag.r)
      |> check_error_code "access" Luv.Error.enoent
    end;
  ]
]