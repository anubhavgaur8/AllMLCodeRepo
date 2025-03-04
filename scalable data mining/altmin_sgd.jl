using Flux
using ArgParse
using Printf: @printf, @sprintf

include("utils/utils.jl")
include("altmin.jl")

function parse_commandline()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--model"
            help = "name of model: \"feedforward\", \"binary\" or \"LeNet\""
            arg_type = String
            default = "feedforward"
        "--n_hidden_layers"
            help = "number of hidden layers (ignored for LeNet)"
            arg_type = Int32
            default = Int32(2)
        "--n_hiddens"
            help = "number of hidden units (ignored for LeNet)"
            arg_type = Int32
            default = Int32(100)
        "--dataset"
            help = "name of dataset"
            arg_type = String
            default = "mnist"
        "--data_augmentation"
            help = "enables data augmentation"
            action = :store_true
        "--batch_size"
            help = "input batch size for training"
            arg_type = Int32
            default = Int32(200)
        "--epochs"
            help = "number of epochs to train for"
            arg_type = Int32
            default = Int32(50)
        "--n_iter_codes"
            help = "number of internal iterations for codes optimization"
        arg_type = Int32
            default = Int32(5)
        "--n_iter_weights"
            help = "number of internal iterations for learning weights"
            arg_type = Int32
            default = Int32(1)
        "--lr_codes"
            help = "learning rate for codes update"
            arg_type = Float32
            default = Float32(0.3)
        "--lr_out"
            help = "learning rate for last layer weights updates"
            arg_type = Float32
            default = Float32(0.008)
        "--lr_weights"
            help = "learning rate for hidden weights updates"
            arg_type = Float32
            default = Float32(0.008)
        "--lr_half_epochs"
            help = "number of epochs after which learning rate is halved"
            arg_type = Int32
            default = Int32(8)
        "--no_batchnorm"
            help = "disables batch-normalisation"
            action = :store_true
        "--lambda_c"
            help = "codes sparsity"
            arg_type = Float32
            default = Float32(0)
        "--lambda_w"
            help = "weight sparsity"
            arg_type = Float32
            default = Float32(0.0)
        "--mu"
            help = "initial mu parameter"
            arg_type = Float32
            default = Float32(0.003)
        "--d_mu"
            help = "increase in mu after every mini-batch"
            arg_type = Float32
            default = Float32(1 / 300)
        "--postprocessing_steps"
            help = "number of Carreirs-Peripinan post-processing steps after training"
            arg_type = Int32
            default = Int32(0)
        "--seed"
            help = "random seed"
            arg_type = Int32
            default = Int32(1)
        "--log_interval"
            help = "how many batches to wait before logging training status"
            arg_type = Int32
            default = Int32(100)
        "--save_interval"
            help = "how many batches to wait before saving test performance (if set to zero, it does not save)"
            arg_type = Int32
            default = Int32(1000)
        "--log_first_epoch"
            help = "whether or not it should test and log after every mini-batch in first epoch"
            action = :store_true
        "--no_cuda"
            help = "disables CUDA training"
            action = :store_true
    end

    return parse_args(s, as_symbols=true)
end

function main()
    args = parse_commandline()

    model_name = lowercase(args[:model])
    if model_name == "feedforward" || model_name == "binary"
        model_name = "$(model_name)_$(args[:n_hidden_layers])x$(args[:n_hiddens])"
    end
    file_name = "save_adam_baseline_$(model_name)_$(args[:dataset])_$(args[:seed]).pt"
    
    println("\nOnline alternating-minimization with SGD")
    println("* Loading dataset: $(args[:dataset])")
    println("* Loading model: $(model_name)")
    println("      BatchNorm: $(!args[:no_batchnorm])")

    if lowercase(args[:model]) == "feedforward" || lowercase(args[:model]) == "binary"
        trainloader, testloader, n_inputs = Utils.load_dataset(;namedataset=args[:dataset], batch_size=args[:batch_size])
        model = Models.FFNet(n_inputs=n_inputs, n_hiddens=args[:n_hiddens], n_hidden_layers=args[:n_hidden_layers],
                batchnorm=!args[:no_batchnorm], bias=true)
    elseif lowercase(args[:model]) == "lenet"
        trainloader, testloader, n_inputs = Utils.load_dataset(;namedataset=args[:dataset], batch_size=args[:batch_size], 
            conv_net=true, data_aug=args[:data_augmentation])
        if args[:data_augmentation]
            println("    data augmentation")
        end

        first_data = first(trainloader).data
        window_size = size(first_data, 1)
        if ndims(first_data) == 3
            num_input_channels = size(first_data, 3)
        else
            num_input_channels = 1
        end

        model = Models.LeNet(;num_input_channels=num_input_channels, window_size=window_size, bias=true)
    end

    # Multi-GPU?

    loss((x, y)) = Flux.Losses.logitcrossentropy(x, y)
    model_loss((x, y)) = Flux.Losses.logitcrossentropy(model(x), y)
    optimizer = Flux.Optimise.ADAM(args[:lr_weights])
    scheduler(epoch) = args[:lr_weights] / 2^(epoch ÷ args[:lr_half_epochs])

    model = Altmin.get_mods(model, optimizer, scheduler)
    # Last layer params?

    # Specially handle binary model?

    # Initial mu and increment after every mini-batch
    μ = args[:mu]
    μ_max = 10 * args[:mu]

    perf = Utils.Performance()

    for epoch = 1:args[:epochs]
        Altmin.scheduler_step(model, epoch)

        @printf "Epoch %d of %d, μ = %.4f, lr_out = %f\n" epoch args[:epochs] μ scheduler(epoch)

        for (batchidx, (x, y)) in enumerate(trainloader)
            train_loss = model_loss((x, y))

            # (1) Forward
            outputs, codes = Altmin.get_codes(model, x)

            # (2) Update codes
            codes = Altmin.update_codes(codes, model, y, loss, μ, args[:lambda_c], args[:n_iter_codes], args[:lr_codes])

            # (3) Update weights
            Altmin.update_last_layer(model.model_mods[end], codes[end], 
                    y, loss, args[:n_iter_weights])

            Altmin.update_hidden_weights_adam(model, x, codes, 
                    args[:lambda_w], args[:n_iter_weights])

            # Print to terminal
            if epoch == 1 && args[:log_first_epoch]
                push!(perf.first_epoch, Models.test(model, testloader, label=" - Test"))
            end

            if (batchidx - 1) % args[:log_interval] == 0
                train_loss_str = @sprintf "%.6f" train_loss
                println(" Train Epoch $epoch, Minibatch $batchidx: Train-loss = $train_loss_str")
            end

            if args[:save_interval] > 0 && (batchidx - 1) % args[:save_interval] == 0 && batchidx > 1
                acc = Models.test(model, test_loader, label=" - Test")
                push!(perf.te_vs_iter, acc)
            end

            if μ < μ_max
                μ += args[:d_mu]
            end
        end

        push!(perf.tr, Models.test(model, trainloader, label="Training"))
        push!(perf.te, Models.test(model, testloader, label="Test"))
    end

    # Save data?
end

main()
    