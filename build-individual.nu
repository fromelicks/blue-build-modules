#!/usr/bin/env nu
# build separate images for each module in the repo

use constants.nu *

print $"(ansi green_bold)Gathering images"

let is_pull_request = $env.GH_EVENT_NAME == "pull_request"
let changed_files = if $is_pull_request {
    git diff --name-only $"($env.GH_BASE_SHA)...HEAD" | lines
} else {
    []
}
let rebuild_inputs = [
    ".github/workflows/build-reusable.yml"
    ".github/workflows/build.yml"
    "build-individual.nu"
    "constants.nu"
    "cosign.key"
    "cosign.pub"
    "individual.Containerfile"
]
let rebuild_all = (
    ($is_pull_request == false)
    or ($env.REBUILD_ALL_IMAGES | into bool)
    or ($changed_files | any { |path| $path in $rebuild_inputs })
)
let changed_modules = (
    $changed_files
    | where { |path| $path starts-with "modules/" }
    | each { |path| $path | split row "/" | get 1 }
    | uniq
)

if $is_pull_request and ($rebuild_all == false) {
    print $"(ansi cyan)Changed modules:(ansi reset) ($changed_modules | str join ' ')"
}

let module_dirs = (
    ls modules
    | where { |moduleDir|
        $rebuild_all or (($moduleDir.name | path basename) in $changed_modules)
    }
)

let images = $module_dirs | each { |moduleDir|
    cd $moduleDir.name

    # module is unversioned
    if (glob $"($moduleDir.name | path basename).{sh,nu}" | any { path exists }) {

        print $"(ansi cyan)Found(ansi reset) (ansi cyan_bold)unversioned(ansi reset) (ansi cyan)module:(ansi reset) ($moduleDir.name | path basename)"

        let tags = (
            if ($env.GH_EVENT_NAME != "pull_request" and $env.GH_BRANCH == "main") {
                ["latest", "v1"]
            } else if ($env.GH_EVENT_NAME != "pull_request") {
                [$env.GH_BRANCH, $"v1-($env.GH_BRANCH)"]
            } else {
                [$"pr-($env.GH_PR_NUMBER)", $"v1-pr-($env.GH_PR_NUMBER)"]
            }
        )
        print $"(ansi cyan)Generated tags:(ansi reset) ($tags | str join ' ')"

        {
            name: ($moduleDir.name | path basename)
            directory: ($moduleDir.name)
            tags: $tags
        }

    } else { # module is versioned

        print $"(ansi cyan)Found(ansi reset) (ansi blue_bold)versioned(ansi reset) (ansi cyan)module:(ansi reset) ($moduleDir.name | path basename)"

        let versioned = ls v*/
            | get name | str substring 1.. | into int | sort # sort versions properly
            | each {|version|
                let tags = (
                    if ($env.GH_EVENT_NAME != "pull_request" and $env.GH_BRANCH == "main") {
                        [$"v($version)"]
                    } else if ($env.GH_EVENT_NAME != "pull_request") {
                        [$"v($version)-($env.GH_BRANCH)"]
                    } else {
                        [$"v($version)-pr-($env.GH_PR_NUMBER)"]
                    }
                )
                print $"(ansi cyan)Generated tags:(ansi reset) ($tags | str join ' ')"

                {
                    name: ($moduleDir.name | path basename)
                    directory: $"($moduleDir.name)/v($version)"
                    tags: $tags
                }
        }

        let latest_tag = (
            if ($env.GH_EVENT_NAME != "pull_request" and $env.GH_BRANCH == "main") {
                "latest"
            } else if ($env.GH_EVENT_NAME != "pull_request") {
                $env.GH_BRANCH
            } else {
                $"pr-($env.GH_PR_NUMBER)"
            }
        )
        print $"(ansi cyan)Extra tag for latest image:(ansi reset) ($latest_tag)"
        let latest = ($versioned | last)
        ($versioned
            | update (($versioned | length) - 1) # update the last / latest item in list
            ($latest | update "tags" ($latest.tags | append $latest_tag)) # append tag which should only be given to the latest version
        )

    }
} | flatten directory

print $"(ansi green_bold)Starting image build(ansi reset)"

let recursive_signing = if $env.GH_EVENT_NAME == "pull_request" { [] } else { ["--recursive"] }

$images | par-each { |img|

    print $"(ansi cyan)Building image:(ansi reset) modules/($img.name)"
    (docker build .
        -f ./individual.Containerfile
        --push
        ...($PLATFORMS | each { $'--platform=($in)' })
        ...($img.tags | each { |tag| ["-t", $"($env.REGISTRY)/modules/($img.name):($tag)"] } | flatten) # generate and spread list of tags
        --build-arg $"DIRECTORY=($img.directory)"
        --build-arg $"NAME=($img.name)"
        --annotation $"index,manifest:org.opencontainers.image.created=(date now | date to-timezone UTC | format date '%Y-%m-%dT%H:%M:%SZ')"
        --annotation "index,manifest:org.opencontainers.image.url=https://github.com/blue-build/modules"
        --annotation $"index,manifest:org.opencontainers.image.documentation=https://blue-build.org/reference/modules/($img.name)/"
        --annotation "index,manifest:org.opencontainers.image.source=https://github.com/blue-build/modules"
        --annotation "index,manifest:org.opencontainers.image.version=nightly"
        --annotation $"index,manifest:org.opencontainers.image.revision=($env.GITHUB_SHA)"
        --annotation "index,manifest:org.opencontainers.image.licenses=Apache-2.0"
        --annotation $"index,manifest:org.opencontainers.image.title=BlueBuild Module: ($img.name)"
        --annotation "index,manifest:org.opencontainers.image.description=BlueBuild standard modules used for building your Atomic Images"
    )

    let inspect_image = $'($env.REGISTRY)/modules/($img.name):($img.tags | first)'
    print $"(ansi cyan)Inspecting image:(ansi reset) ($inspect_image)"
    let digest = (docker
        buildx
        imagetools
        inspect
        --format '{{json .}}'
        $inspect_image)
        | from json
        | get manifest.digest

    let digest_image = $'($env.REGISTRY)/modules/($img.name)@($digest)'
    print $"(ansi cyan)Signing image:(ansi reset) ($digest_image)"
    (cosign sign
        --new-bundle-format=false
        --use-signing-config=false
        -y ...($recursive_signing)
        --key env://COSIGN_PRIVATE_KEY
        $digest_image)
    (cosign verify
        --key=./cosign.pub
        $digest_image)
}

print $"(ansi green_bold)DONE!(ansi reset)"
