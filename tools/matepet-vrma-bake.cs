using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UniGLTF;
using UnityEditor;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;
using UniVRM10;

/// <summary>
/// Offline bake: Mate-Engine Unity Humanoid .anim clips -> standard .vrma.
///
/// Why Unity: the clips are Unity muscle curves (RootT/RootQ + muscle names).
/// Unity's Avatar already knows the exact muscle-to-local-rotation conversion
/// and the Zome humanoid mapping; re-implementing that in JS/Swift is how the
/// procedural pet ended up with wrong axes. Sampling through an Animator and
/// exporting with UniVRM's VrmAnimationExporter gives us the same rotations
/// Mate-Engine itself sees.
///
/// Run:
///   Unity -batchmode -nographics -quit \
///     -projectPath Mate-Engine \
///     -executeMethod UniVRM10.MatePetBake.Bake \
///     -logFile /tmp/matepet-bake.log
/// </summary>
namespace UniVRM10
{
    internal static class MatePetBake
    {
        private struct ClipSpec
        {
            public string AssetPath;
            public string OutputName;
            public ClipSpec(string assetPath, string outputName)
            {
                AssetPath = assetPath;
                OutputName = outputName;
            }
        }

        private static readonly ClipSpec[] Clips =
        {
            new("Assets/MATE ENGINE - Animations/UPDATE_2/PET_IDLE_UPDATE2_01.anim", "idle_01"),
            new("Assets/MATE ENGINE - Animations/UPDATE_2/PET_IDLE_UPDATE2_02.anim", "idle_02"),
            new("Assets/MATE ENGINE - Animations/UPDATE_2/PET_IDLE_UPDATE2_03.anim", "idle_03"),
            new("Assets/MATE ENGINE - Animations/UPDATE_2/PET_IDLE_UPDATE2_04.anim", "idle_04"),
            new("Assets/MATE ENGINE - Animations/UPDATE_2/PET_TALKING.anim", "talk"),
            new("Assets/MATE ENGINE - Animations/PET_MISC/PET_HAPPY.anim", "happy"),
            new("Assets/MATE ENGINE - Animations/PET_MISC/PET_LAUGHING.anim", "laugh"),
            new("Assets/MATE ENGINE - Animations/PET_MISC/PET_DRAGGING.anim", "drag"),
            new("Assets/MATE ENGINE - Animations/PET_MISC/PET_SHY_POINT.anim", "shy"),
            new("Assets/MATE ENGINE - Animations/PET_DANCING/PET_DANCING.anim", "dance_01"),
            new("Assets/MATE ENGINE - Animations/PET_DANCING/PET_DANCING_2.anim", "dance_02"),
            new("Assets/MATE ENGINE - Animations/PET_DANCING/PET_DANCING_3.anim", "dance_03"),
            new("Assets/MATE ENGINE - Animations/PET_DANCING/PET_DANCING_4.anim", "dance_04"),
            new("Assets/MATE ENGINE - Animations/PET_SLEEPING/PET_SLEEPING.anim", "sleep"),
            new("Assets/MATE ENGINE - Animations/PET_LOCOMOTION/PET_WALK_LEFT.anim", "walk_left"),
            new("Assets/MATE ENGINE - Animations/PET_LOCOMOTION/PET_WALK_RIGHT.anim", "walk_right"),
            new("Assets/MATE ENGINE - Animations/PET_HIDING/PET_HIDE.anim", "hide"),
            new("Assets/MATE ENGINE - Animations/PET_POSE/PET_POSE_1.anim", "pose_01"),
            new("Assets/MATE ENGINE - Animations/PET_INTRO/PET_INTRO.anim", "intro"),
        };

        [MenuItem("MatePet/Bake Unity Animations to VRMA")]
        public static void Bake()
        {
            const string prefabPath = "Assets/MATE ENGINE - Avatar/Zome.prefab";
            var prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            if (prefab == null)
            {
                Fail($"prefab not found: {prefabPath}");
                return;
            }

            var outputDir = Path.GetFullPath(Path.Combine(Application.dataPath,
                "../../Sources/MatePet/Resources/Animations"));
            Directory.CreateDirectory(outputDir);
            Debug.Log($"[MatePetBake] output: {outputDir}");

            var instance = UnityEngine.Object.Instantiate(prefab);
            instance.name = "MatePetBake_Zome";
            instance.transform.position = Vector3.zero;
            instance.transform.rotation = Quaternion.identity;

            // The exporter only needs the node graph. Renderers would drag
            // meshes/materials into the VRMA and make it huge.
            foreach (var renderer in instance.GetComponentsInChildren<Renderer>(true))
                UnityEngine.Object.DestroyImmediate(renderer);
            foreach (var filter in instance.GetComponentsInChildren<MeshFilter>(true))
                UnityEngine.Object.DestroyImmediate(filter);

            var animator = instance.GetComponentInChildren<Animator>(true);
            if (animator == null || animator.avatar == null || !animator.avatar.isHuman)
            {
                Fail("Zome prefab has no humanoid Animator/Avatar");
                UnityEngine.Object.DestroyImmediate(instance);
                return;
            }
            animator.applyRootMotion = false;

            var boneMap = new Dictionary<HumanBodyBones, Transform>();
            foreach (HumanBodyBones bone in Enum.GetValues(typeof(HumanBodyBones)))
            {
                if (bone == HumanBodyBones.LastBone) continue;
                var t = animator.GetBoneTransform(bone);
                if (t != null) boneMap[bone] = t;
            }
            Debug.Log($"[MatePetBake] humanoid bones: {boneMap.Count}");

            var baked = 0;
            foreach (var spec in Clips)
            {
                var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(spec.AssetPath);
                if (clip == null)
                {
                    Debug.LogWarning($"[MatePetBake] skip missing clip: {spec.AssetPath}");
                    continue;
                }
                if (!clip.isHumanMotion)
                {
                    Debug.LogWarning($"[MatePetBake] skip non-humanoid clip: {spec.AssetPath}");
                    continue;
                }
                try
                {
                    BakeClip(instance, animator, boneMap, clip, spec.OutputName, outputDir);
                    baked++;
                    Debug.Log($"[MatePetBake] baked {spec.OutputName} ({clip.length:0.00}s)");
                }
                catch (Exception e)
                {
                    Debug.LogError($"[MatePetBake] failed {spec.OutputName}: {e}");
                }
            }

            UnityEngine.Object.DestroyImmediate(instance);
            AssetDatabase.Refresh();
            Debug.Log($"[MatePetBake] done: {baked}/{Clips.Length} clips");
            if (Application.isBatchMode) EditorApplication.Exit(baked == Clips.Length ? 0 : 1);
        }

        private static void BakeClip(GameObject root,
                                     Animator animator,
                                     Dictionary<HumanBodyBones, Transform> boneMap,
                                     AnimationClip clip,
                                     string outputName,
                                     string outputDir)
        {
            var data = new ExportingGltfData();
            using var exporter = new VrmAnimationExporter(data, new GltfExportSettings());
            exporter.Prepare(root);

            exporter.Export(vrma =>
            {
                // Hips translation is relative to the model root, which is
                // what the VRMA position channel expects.
                if (!boneMap.TryGetValue(HumanBodyBones.Hips, out var hips))
                    throw new InvalidOperationException("no Hips bone");
                vrma.SetPositionBoneAndParent(hips, root.transform);

                foreach (var kv in boneMap)
                {
                    var vrmBone = Vrm10HumanoidBoneSpecification.ConvertFromUnityBone(kv.Key);
                    var parent = GetParentBone(boneMap, vrmBone) ?? root.transform;
                    vrma.AddRotationBoneAndParent(kv.Key, kv.Value, parent);
                }

                var graph = PlayableGraph.Create($"MatePetBake_{outputName}");
                graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
                var playable = AnimationClipPlayable.Create(graph, clip);
                var output = AnimationPlayableOutput.Create(graph, "out", animator);
                output.SetSourcePlayable(playable);
                graph.Play();

                var fps = 60f;
                var frames = Mathf.Max(1, Mathf.CeilToInt(clip.length * fps));
                float last = -1f;
                for (var i = 0; i < frames; i++)
                {
                    var t = i / fps;
                    if (t > clip.length) break;
                    if (t <= last + 1e-5f) continue;
                    last = t;
                    playable.SetTime(t);
                    graph.Evaluate(0);
                    // Humanoid muscle evaluation writes the bone transforms;
                    // read them only after Evaluate.
                    vrma.AddFrame(TimeSpan.FromSeconds(t));
                }
                // The last sample can round to the previous float; only add it
                // when it is genuinely later, otherwise VRMKit rejects the
                // sampler as non-strictly-increasing.
                if (clip.length > last + 1e-4f)
                {
                    playable.SetTime(clip.length);
                    graph.Evaluate(0);
                    vrma.AddFrame(TimeSpan.FromSeconds(clip.length));
                }

                playable.Destroy();
                graph.Destroy();
            });

            var path = Path.Combine(outputDir, outputName + ".vrma");
            File.WriteAllBytes(path, data.ToGlbBytes());
        }

        private static Transform GetParentBone(Dictionary<HumanBodyBones, Transform> map,
                                               Vrm10HumanoidBones bone)
        {
            while (true)
            {
                if (bone == Vrm10HumanoidBones.Hips) break;
                var parentBone = Vrm10HumanoidBoneSpecification.GetDefine(bone).ParentBone.Value;
                var unityParentBone = Vrm10HumanoidBoneSpecification.ConvertToUnityBone(parentBone);
                if (map.TryGetValue(unityParentBone, out var found)) return found;
                bone = parentBone;
            }
            return null;
        }

        private static void Fail(string message)
        {
            Debug.LogError($"[MatePetBake] {message}");
            if (Application.isBatchMode) EditorApplication.Exit(1);
        }
    }
}