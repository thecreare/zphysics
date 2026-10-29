const std = @import("std");
const Translator = @import("translate_c").Translator;

fn addMacros(module: *std.Build.Module, options: anytype) void {
    if (options.enable_cross_platform_determinism)
        module.addCMacro("JPH_CROSS_PLATFORM_DETERMINISTIC", "");
    if (options.enable_debug_renderer)
        module.addCMacro("JPH_DEBUG_RENDERER", "");
    if (options.use_double_precision)
        module.addCMacro("JPH_DOUBLE_PRECISION", "");
    if (options.enable_asserts)
        module.addCMacro("JPH_ENABLE_ASSERTS", "");
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .use_double_precision = b.option(
            bool,
            "use_double_precision",
            "Enable double precision",
        ) orelse false,
        .enable_asserts = b.option(
            bool,
            "enable_asserts",
            "Enable assertions",
        ) orelse (optimize == .Debug),
        .enable_cross_platform_determinism = b.option(
            bool,
            "enable_cross_platform_determinism",
            "Enables cross-platform determinism",
        ) orelse true,
        .enable_debug_renderer = b.option(
            bool,
            "enable_debug_renderer",
            "Enable debug renderer",
        ) orelse false,
        .shared = b.option(
            bool,
            "shared",
            "Build JoltC as shared lib",
        ) orelse false,
        .no_exceptions = b.option(
            bool,
            "no_exceptions",
            "Disable C++ Exceptions",
        ) orelse true,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }
    const options_module = options_step.createModule();

    const libjoltc = buildLibjoltc(b, target, optimize, options);
    const translate_c = b.dependency("translate_c", .{});
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <jc.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    t.linkLibrary(libjoltc);

    const zjolt = b.addModule("root", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zphysics.zig"),
        .imports = &.{
            .{ .name = "zphysics_options", .module = options_module },
            .{ .name = "c", .module = t.mod },
        },
    });


    const test_step = b.step("test", "Run zphysics tests");
    const tests = b.addTest(.{
        .name = "zphysics-tests",
        .use_llvm = true,
        .root_module = zjolt,
    });
    b.installArtifact(tests);

    // TODO: Problems with LTO on Windows.
    if (target.result.os.tag == .windows) {
        tests.lto = .none;
    }

    tests.root_module.addCSourceFile(.{
        .file = b.path("libs/JoltC/JoltPhysicsC_Tests.c"),
        .flags = &.{
            "-fno-sanitize=undefined",
        },
    });

    if (b.option(bool, "verbose", "Print verbose test debug output to stderr") orelse false)
        tests.root_module.addCMacro("PRINT_OUTPUT", "");

    test_step.dependOn(&b.addRunArtifact(tests).step);
}

pub fn buildLibjoltc(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: anytype,
) *std.Build.Step.Compile {
    const joltc_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addMacros(joltc_module, options);
    if (options.shared and target.result.os.tag == .windows)
        joltc_module.addCMacro("JPC_API", "extern __declspec(dllexport)");

    joltc_module.addIncludePath(b.path("libs"));
    joltc_module.addIncludePath(b.path("libs/JoltC"));
    if (target.result.abi != .msvc) {
        joltc_module.link_libcpp = true;
    } else {
        joltc_module.linkSystemLibrary("advapi32", .{});
    }

    const c_flags = &.{
        "-std=c++17",
        if (options.no_exceptions) "-fno-exceptions" else "",
        "-fno-access-control",
        "-fno-sanitize=undefined",
    };

    joltc_module.addCSourceFiles(.{
        .flags = c_flags,
        .root = b.path("libs/JoltC"),
        .files = &.{
            "JoltPhysicsC.cpp",
            "JoltPhysicsC_Extensions.cpp",
        }
    });
    joltc_module.addCSourceFiles(.{
        .flags = c_flags,
        .root = b.path("libs/Jolt"),
        .files = jolt_source_files,
    });

    const user_extensions = b.option(
        []const std.Build.LazyPath,
        "user_extensions",
        "List of user source files to add to the joltc library",
    ) orelse &.{};
    for (user_extensions) |user_extension| {
        joltc_module.addCSourceFile(.{
            .file = user_extension,
            .flags = c_flags,
        });
    }

    const libjoltc = b.addLibrary(.{
        .name = "joltc",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = joltc_module,
        .use_llvm = true, 
    });
    libjoltc.installHeader(b.path("libs/JoltC/JoltPhysicsC.h"), "jc.h");
    return libjoltc;
}

const jolt_source_files = &.{
    "AABBTree/AABBTreeBuilder.cpp",
    "Core/Color.cpp",
    "Core/Factory.cpp",
    "Core/IssueReporting.cpp",
    "Core/JobSystemSingleThreaded.cpp",
    "Core/JobSystemThreadPool.cpp",
    "Core/JobSystemWithBarrier.cpp",
    "Core/LinearCurve.cpp",
    "Core/Memory.cpp",
    "Core/Profiler.cpp",
    "Core/RTTI.cpp",
    "Core/Semaphore.cpp",
    "Core/StringTools.cpp",
    "Core/TickCounter.cpp",
    "Geometry/ConvexHullBuilder.cpp",
    "Geometry/ConvexHullBuilder2D.cpp",
    "Geometry/Indexify.cpp",
    "Geometry/OrientedBox.cpp",
    "Math/Vec3.cpp",
    "ObjectStream/ObjectStream.cpp",
    "ObjectStream/ObjectStreamBinaryIn.cpp",
    "ObjectStream/ObjectStreamBinaryOut.cpp",
    "ObjectStream/ObjectStreamIn.cpp",
    "ObjectStream/ObjectStreamOut.cpp",
    "ObjectStream/ObjectStreamTextIn.cpp",
    "ObjectStream/ObjectStreamTextOut.cpp",
    "ObjectStream/SerializableObject.cpp",
    "ObjectStream/TypeDeclarations.cpp",
    "Physics/Body/Body.cpp",
    "Physics/Body/BodyCreationSettings.cpp",
    "Physics/Body/BodyInterface.cpp",
    "Physics/Body/BodyManager.cpp",
    "Physics/Body/MassProperties.cpp",
    "Physics/Body/MotionProperties.cpp",
    "Physics/Character/Character.cpp",
    "Physics/Character/CharacterBase.cpp",
    "Physics/Character/CharacterVirtual.cpp",
    "Physics/Collision/BroadPhase/BroadPhase.cpp",
    "Physics/Collision/BroadPhase/BroadPhaseBruteForce.cpp",
    "Physics/Collision/BroadPhase/BroadPhaseQuadTree.cpp",
    "Physics/Collision/BroadPhase/QuadTree.cpp",
    "Physics/Collision/CastConvexVsTriangles.cpp",
    "Physics/Collision/CastSphereVsTriangles.cpp",
    "Physics/Collision/CollideConvexVsTriangles.cpp",
    "Physics/Collision/CollideSphereVsTriangles.cpp",
    "Physics/Collision/CollisionDispatch.cpp",
    "Physics/Collision/CollisionGroup.cpp",
    "Physics/Collision/EstimateCollisionResponse.cpp",
    "Physics/Collision/GroupFilter.cpp",
    "Physics/Collision/GroupFilterTable.cpp",
    "Physics/Collision/ManifoldBetweenTwoFaces.cpp",
    "Physics/Collision/NarrowPhaseQuery.cpp",
    "Physics/Collision/NarrowPhaseStats.cpp",
    "Physics/Collision/PhysicsMaterial.cpp",
    "Physics/Collision/PhysicsMaterialSimple.cpp",
    "Physics/Collision/Shape/BoxShape.cpp",
    "Physics/Collision/Shape/CapsuleShape.cpp",
    "Physics/Collision/Shape/CompoundShape.cpp",
    "Physics/Collision/Shape/ConvexHullShape.cpp",
    "Physics/Collision/Shape/ConvexShape.cpp",
    "Physics/Collision/Shape/CylinderShape.cpp",
    "Physics/Collision/Shape/DecoratedShape.cpp",
    "Physics/Collision/Shape/EmptyShape.cpp",
    "Physics/Collision/Shape/HeightFieldShape.cpp",
    "Physics/Collision/Shape/MeshShape.cpp",
    "Physics/Collision/Shape/MutableCompoundShape.cpp",
    "Physics/Collision/Shape/OffsetCenterOfMassShape.cpp",
    "Physics/Collision/Shape/PlaneShape.cpp",
    "Physics/Collision/Shape/RotatedTranslatedShape.cpp",
    "Physics/Collision/Shape/ScaledShape.cpp",
    "Physics/Collision/Shape/Shape.cpp",
    "Physics/Collision/Shape/SphereShape.cpp",
    "Physics/Collision/Shape/StaticCompoundShape.cpp",
    "Physics/Collision/Shape/TaperedCapsuleShape.cpp",
    "Physics/Collision/Shape/TaperedCylinderShape.cpp",
    "Physics/Collision/Shape/TriangleShape.cpp",
    "Physics/Collision/TransformedShape.cpp",
    "Physics/Constraints/ConeConstraint.cpp",
    "Physics/Constraints/Constraint.cpp",
    "Physics/Constraints/ConstraintManager.cpp",
    "Physics/Constraints/ContactConstraintManager.cpp",
    "Physics/Constraints/DistanceConstraint.cpp",
    "Physics/Constraints/FixedConstraint.cpp",
    "Physics/Constraints/GearConstraint.cpp",
    "Physics/Constraints/HingeConstraint.cpp",
    "Physics/Constraints/MotorSettings.cpp",
    "Physics/Constraints/PathConstraint.cpp",
    "Physics/Constraints/PathConstraintPath.cpp",
    "Physics/Constraints/PathConstraintPathHermite.cpp",
    "Physics/Constraints/PointConstraint.cpp",
    "Physics/Constraints/PulleyConstraint.cpp",
    "Physics/Constraints/RackAndPinionConstraint.cpp",
    "Physics/Constraints/SixDOFConstraint.cpp",
    "Physics/Constraints/SliderConstraint.cpp",
    "Physics/Constraints/SpringSettings.cpp",
    "Physics/Constraints/SwingTwistConstraint.cpp",
    "Physics/Constraints/TwoBodyConstraint.cpp",
    "Physics/DeterminismLog.cpp",
    "Physics/IslandBuilder.cpp",
    "Physics/LargeIslandSplitter.cpp",
    "Physics/PhysicsScene.cpp",
    "Physics/PhysicsSystem.cpp",
    "Physics/PhysicsUpdateContext.cpp",
    "Physics/Ragdoll/Ragdoll.cpp",
    "Physics/SoftBody/SoftBodyCreationSettings.cpp",
    "Physics/SoftBody/SoftBodyMotionProperties.cpp",
    "Physics/SoftBody/SoftBodyShape.cpp",
    "Physics/SoftBody/SoftBodySharedSettings.cpp",
    "Physics/StateRecorderImpl.cpp",
    "Physics/Vehicle/MotorcycleController.cpp",
    "Physics/Vehicle/TrackedVehicleController.cpp",
    "Physics/Vehicle/VehicleAntiRollBar.cpp",
    "Physics/Vehicle/VehicleCollisionTester.cpp",
    "Physics/Vehicle/VehicleConstraint.cpp",
    "Physics/Vehicle/VehicleController.cpp",
    "Physics/Vehicle/VehicleDifferential.cpp",
    "Physics/Vehicle/VehicleEngine.cpp",
    "Physics/Vehicle/VehicleTrack.cpp",
    "Physics/Vehicle/VehicleTransmission.cpp",
    "Physics/Vehicle/Wheel.cpp",
    "Physics/Vehicle/WheeledVehicleController.cpp",
    "RegisterTypes.cpp",
    "Renderer/DebugRenderer.cpp",
    "Renderer/DebugRendererPlayback.cpp",
    "Renderer/DebugRendererRecorder.cpp",
    "Renderer/DebugRendererSimple.cpp",
    "Skeleton/SkeletalAnimation.cpp",
    "Skeleton/Skeleton.cpp",
    "Skeleton/SkeletonMapper.cpp",
    "Skeleton/SkeletonPose.cpp",
    "TriangleSplitter/TriangleSplitter.cpp",
    "TriangleSplitter/TriangleSplitterBinning.cpp",
    "TriangleSplitter/TriangleSplitterMean.cpp",
};
