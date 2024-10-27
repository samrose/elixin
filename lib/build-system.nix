{ lib, stdenv, elixir, writeText, writeScript }:

let
  # Create the orchestrator script that uses external cache
  mkOrchestrator = steps: writeScript "build-orchestrator.exs" ''
    Mix.install([
      {:jason, "~> 1.4"}
    ])

    defmodule BuildCache do
      @moduledoc """
      Handles build state persistence outside the Nix sandbox
      """
      
      def cache_dir do
        # Use XDG cache directory or fallback
        System.get_env("XDG_CACHE_HOME")
        |> case do
          nil -> Path.join([System.get_env("HOME"), ".cache"])
          dir -> dir
        end
        |> Path.join("nix-build-cache")
      end
      
      def init_cache do
        cache_dir = cache_dir()
        File.mkdir_p!(cache_dir)
        cache_dir
      end
      
      def store_result(step_name, result_path) do
        cache_path = Path.join(cache_dir(), step_name)
        File.cp_r!(result_path, cache_path)
      end
      
      def restore_result(step_name, target_path) do
        cache_path = Path.join(cache_dir(), step_name)
        if File.exists?(cache_path) do
          File.cp_r!(cache_path, target_path)
          true
        else
          false
        end
      end
      
      def step_hash(step_name) do
        path = Path.join(cache_dir(), "#{step_name}.hash")
        case File.read(path) do
          {:ok, hash} -> hash
          _ -> nil
        end
      end
      
      def store_step_hash(step_name, hash) do
        path = Path.join(cache_dir(), "#{step_name}.hash")
        File.write!(path, hash)
      end
    end

    defmodule BuildOrchestrator do
      @moduledoc """
      Orchestrates Nix derivations with persistent caching
      """
      
      def run(steps) do
        # Initialize cache directory
        BuildCache.init_cache()
        
        # Execute steps
        steps
        |> Enum.reduce_while(:ok, fn step, :ok ->
          case build_step(step) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, step.name, reason}}
          end
        end)
      end
      
      defp build_step(step) do
        if step_needs_rebuild?(step) do
          IO.puts("Building step: #{step.name}")
          
          # Run Nix build
          case run_nix_build(step) do
            :ok ->
              # Cache successful result
              BuildCache.store_result(
                step.name,
                "result-#{step.name}"
              )
              # Store new hash
              BuildCache.store_step_hash(
                step.name,
                compute_step_hash(step)
              )
              :ok
              
            error -> error
          end
        else
          IO.puts("Restoring cached step: #{step.name}")
          
          # Restore from cache
          BuildCache.restore_result(
            step.name,
            "result-#{step.name}"
          )
          :ok
        end
      end
      
      defp step_needs_rebuild?(step) do
        current_hash = compute_step_hash(step)
        cached_hash = BuildCache.step_hash(step.name)
        
        # Rebuild if no cache or hash mismatch
        cached_hash != current_hash
      end
      
      defp compute_step_hash(step) do
        # Hash the step's inputs
        input_hashes = step.inputs
        |> Enum.map(&hash_input/1)
        |> Enum.join("")
        
        # Include step definition in hash
        step_def = :erlang.term_to_binary(%{
          command: step.command,
          env: step.env || %{},
          outputs: step.outputs
        })
        
        :crypto.hash(:sha256, input_hashes <> step_def)
        |> Base.encode16()
      end
      
      defp hash_input(input) do
        # Handle different input types
        cond do
          String.contains?(input, "*") ->
            # For globs, hash all matching files
            Path.wildcard(input)
            |> Enum.sort()
            |> Enum.map(&hash_file/1)
            |> Enum.join("")
            
          File.regular?(input) ->
            # For regular files, hash contents
            hash_file(input)
            
          File.exists?(input) ->
            # For directories, hash all contents
            Path.wildcard(Path.join(input, "**"))
            |> Enum.sort()
            |> Enum.map(&hash_file/1)
            |> Enum.join("")
            
          true ->
            # Handle missing inputs
            "missing:#{input}"
        end
      end
      
      defp hash_file(path) do
        if File.regular?(path) do
          File.stream!(path, [], 2048)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16()
        else
          "nonfile:#{path}"
        end
      end
      
      defp run_nix_build(step) do
        cmd = create_nix_build_command(step)
        
        case System.shell(cmd) do
          {_, 0} -> :ok
          {output, code} ->
            IO.puts(:stderr, output)
            {:error, "nix build failed with code #{code}"}
        end
      end
      
      defp create_nix_build_command(step) do
        """
        nix build \\
          --expr '(import ./. {}).buildStep#{step.name}' \\
          #{format_step_inputs(step)} \\
          --out-link result-#{step.name}
        """
      end
      
      defp format_step_inputs(step) do
        step.inputs
        |> Enum.map(&"--arg input#{hash_string(&1)} ./#{&1}")
        |> Enum.join(" ")
      end
      
      defp hash_string(str) do
        :crypto.hash(:md5, str) |> Base.encode16()
      end
    end

    # Read and parse build steps
    steps = System.get_env("BUILD_STEPS")
    |> Jason.decode!(keys: :atoms!)
    
    case BuildOrchestrator.run(steps) do
      :ok -> System.halt(0)
      {:error, step, reason} ->
        IO.puts(:stderr, "Build failed at step #{step}: #{reason}")
        System.halt(1)
    end
  '';

  # Create a derivation for a single build step
  mkBuildStep = { name, command, inputs, outputs, env ? {} }: stdenv.mkDerivation {
    inherit name;
    
    # Mark as impure build to allow cache access
    __impure = true;
    
    buildInputs = [ elixir ];
    
    buildPhase = ''
      # Create input directories
      mkdir -p inputs
      ${lib.concatMapStrings (input: ''
        ln -s "${input}" "inputs/${baseNameOf input}"
      '') inputs}
      
      # Run build command
      ${command}
    '';
    
    installPhase = ''
      mkdir -p $out
      ${lib.concatMapStrings (output: ''
        if [ -e "${output}" ]; then
          cp -r "${output}" "$out/"
        fi
      '') outputs}
    '';
  };

  # Main function to create a build with cached steps
  mkCachedBuild = { name, steps }: stdenv.mkDerivation {
    inherit name;
    
    # Mark as impure to allow cache access
    __impure = true;
    
    buildInputs = [ elixir ];
    
    # Create individual derivations for each step
    passthru = {
      buildSteps = lib.mapAttrs (name: step:
        mkBuildStep {
          inherit name;
          inherit (step) command inputs outputs;
          env = step.env or {};
        }
      ) steps;
    };
    
    buildPhase = ''
      # Export build steps configuration
      export BUILD_STEPS='${builtins.toJSON steps}'
      
      # Run orchestrator
      ${elixir}/bin/elixir ${mkOrchestrator steps}
    '';
    
    installPhase = ''
      mkdir -p $out
      ${lib.concatMapStrings (step: ''
        if [ -e "result-${step.name}" ]; then
          cp -r result-${step.name}/* $out/
        fi
      '') (builtins.attrValues steps)}
    '';
  };

in {
  inherit mkCachedBuild;
}