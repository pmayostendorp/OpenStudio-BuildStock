# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/measures/measure_writing_guide/

require 'csv'
require 'openstudio'

# start the measure
class BuildExistingModel < OpenStudio::Ruleset::ModelUserScript

  # human readable name
  def name
    return "Build Existing Model"
  end

  # human readable description
  def description
    return "Builds the OpenStudio Model for an existing building."
  end

  # human readable description of modeling approach
  def modeler_description
    return "Builds the OpenStudio Model using the sampling csv file, which contains the specified parameters for each existing building. Based on the supplied building number, those parameters are used to run the OpenStudio measures with appropriate arguments and build up the OpenStudio model."
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    building_id = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("building_id", true)
    building_id.setDisplayName("Building ID")
    building_id.setDescription("The building number (between 1 and the number of samples).")
    args << building_id
    
    number_of_buildings_represented = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("number_of_buildings_represented", false)
    number_of_buildings_represented.setDisplayName("Number of Buildings Represented")
    number_of_buildings_represented.setDescription("The total number of buildings represented by the existing building models.")
    args << number_of_buildings_represented
    
    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
    
    building_id = runner.getIntegerArgumentValue("building_id",user_arguments)
    number_of_buildings_represented = runner.getOptionalIntegerArgumentValue("number_of_buildings_represented",user_arguments)
    
    # Get file/dir paths
    resources_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "resources")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    characteristics_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "housing_characteristics")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    helper_methods_file = File.join(resources_dir, "helper_methods.rb")
    measures_dir = File.join(resources_dir, "measures")
    lookup_file = File.join(resources_dir, "options_lookup.tsv")
    # FIXME: Temporary
    buildstock_csv = File.absolute_path(File.join(characteristics_dir, "buildstock.csv")) # Should have been generated by the Worker Initialization Script (run_sampling.rb) or provided by the project
    
    # Load helper_methods
    require File.join(File.dirname(helper_methods_file), File.basename(helper_methods_file, File.extname(helper_methods_file)))

    # Check file/dir paths exist
    check_dir_exists(measures_dir, runner)
    check_file_exists(lookup_file, runner)
    check_file_exists(buildstock_csv, runner)

    # Retrieve all data associated with sample number
    bldg_data = get_data_for_sample(buildstock_csv, building_id, runner)
    
    # Retrieve order of parameters to run
    parameters_ordered = get_parameters_ordered_from_options_lookup_tsv(resources_dir, characteristics_dir)

    # Obtain measures and arguments to be called
    measures = {}
    parameters_ordered.each do |parameter_name|
        # Get measure name and arguments associated with the option
        option_name = bldg_data[parameter_name]
        print_option_assignment(parameter_name, option_name, runner)
        register_value(runner, parameter_name, option_name)

        get_measure_args_from_option_name(lookup_file, option_name, parameter_name, runner).each do |measure_subdir, args_hash|
            if not measures.has_key?(measure_subdir)
                measures[measure_subdir] = {}
            else
                # Relocate to the end of the hash
                measures[measure_subdir] = measures.delete(measure_subdir)
            end
            # Append args_hash to measures[measure_subdir]
            args_hash.each do |k, v|
                measures[measure_subdir][k] = v
            end
        end

    end
    
    # Create a workflow based on the measures we're going to call. Convenient for debugging.
    workflowJSON = OpenStudio::WorkflowJSON.new
    workflowJSON.setOswPath(File.expand_path("../measures.osw"))
    workflowJSON.addMeasurePath("measures")
    workflowJSON.setSeedFile("seeds/EmptySeedModel.osm")
    steps = OpenStudio::WorkflowStepVector.new
    measures.keys.each do |measure_subdir|
        step = OpenStudio::MeasureStep.new(measure_subdir)
        measures[measure_subdir].each do |k,v|
            next if v.nil?
            step.setArgument(k, v)
        end
        steps.push(step)
    end
    workflowJSON.setWorkflowSteps(steps)
    workflowJSON.save
    
    # Call each measure for sample to build up model
    measures.keys.each do |measure_subdir|
        # Gather measure arguments and call measure
        full_measure_path = File.join(measures_dir, measure_subdir, "measure.rb")
        check_file_exists(full_measure_path, runner)
        
        measure_instance = get_measure_instance(full_measure_path)
        argument_map = get_argument_map(model, measure_instance, measures[measure_subdir], lookup_file, measure_subdir, runner)
        print_measure_call(measures[measure_subdir], measure_subdir, runner)

        if not run_measure(model, measure_instance, argument_map, runner)
            return false
        end
    end
        
    # Determine weight
    if not number_of_buildings_represented.nil?
        total_samples = runner.analysis[:analysis][:problem][:algorithm][:number_of_samples].to_f
        weight = number_of_buildings_represented.get / total_samples
        register_value(runner, "weight", weight.to_s)
    end

    return true

  end
  
  def get_data_for_sample(buildstock_csv, building_id, runner)
    CSV.foreach(buildstock_csv, headers:true) do |sample|
        next if sample["Building"].to_i != building_id
        return sample
    end
    # If we got this far, couldn't find the sample #
    msg = "Could not find row for #{building_id.to_s} in #{File.basename(buildstock_csv).to_s}."
    runner.registerError(msg)
    fail msg
  end
    
end

# register the measure to be used by the application
BuildExistingModel.new.registerWithApplication
