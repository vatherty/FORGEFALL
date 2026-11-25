import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

/** Merge sibling static meshes by material while preserving all groups and anchors. */
export function mergeStaticMeshes(root) {
  let before = 0;
  root.traverse((node) => { if (node.isMesh) before++; });
  const parents = [];
  root.traverse((node) => { if (node.children.some((child) => child.isMesh)) parents.push(node); });
  for (const parent of parents) {
    const batches = new Map();
    for (const child of [...parent.children]) {
      if (!child.isMesh || child.children.length || !child.visible ||
          !child.geometry?.isBufferGeometry || Array.isArray(child.material) ||
          child.isSkinnedMesh || child.morphTargetInfluences?.length) continue;
      const key = `${child.material.uuid}:${Boolean(child.geometry.index)}`;
      if (!batches.has(key)) batches.set(key, []);
      batches.get(key).push(child);
    }
    for (const batch of batches.values()) {
      if (batch.length < 2) continue;
      const geometries = batch.map((mesh) => {
        mesh.updateMatrix();
        const geometry = mesh.geometry.clone();
        geometry.applyMatrix4(mesh.matrix);
        return geometry;
      });
      const combined = mergeGeometries(geometries, false);
      geometries.forEach((geometry) => geometry.dispose());
      if (!combined) continue;
      const merged = new THREE.Mesh(combined, batch[0].material);
      merged.name = `Merged_${batch[0].material.name || 'material'}`;
      merged.castShadow = batch.some((mesh) => mesh.castShadow);
      merged.receiveShadow = batch.some((mesh) => mesh.receiveShadow);
      parent.add(merged);
      for (const mesh of batch) parent.remove(mesh);
    }
  }
  let after = 0;
  root.traverse((node) => { if (node.isMesh) after++; });
  return { before, after };
}
