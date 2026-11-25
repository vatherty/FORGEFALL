import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { mergeStaticMeshes } from './optimize.mjs';

// GLTFExporter still uses the browser FileReader API for Blob conversion.
class NodeFileReader {
  result = null;
  onloadend = null;
  async readAsArrayBuffer(blob) {
    this.result = await blob.arrayBuffer();
    this.onloadend?.();
  }
  async readAsDataURL(blob) {
    this.result = `data:${blob.type};base64,${Buffer.from(await blob.arrayBuffer()).toString('base64')}`;
    this.onloadend?.();
  }
}
globalThis.FileReader ??= NodeFileReader;

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, '../../assets/models/weapons');
const ids = process.argv.slice(2);
if (ids.length === 0) {
  console.error('Usage: node export.mjs <weapon-id> [weapon-id...]');
  process.exitCode = 1;
} else {
  await fs.mkdir(outDir, { recursive: true });
  for (const id of ids) {
    if (!/^[a-z][a-z0-9_]*$/.test(id)) throw new Error(`Invalid weapon id: ${id}`);
    const module = await import(`./${id}.mjs`);
    const factory = Object.values(module).find((value) => typeof value === 'function');
    if (!factory) throw new Error(`${id}.mjs exports no model function`);
    const model = factory(THREE);
    if (!(model instanceof THREE.Group)) throw new Error(`${id} did not return THREE.Group`);
    model.name = `Weapon_${id}`;
    const anchors = {};
    let meshes = 0;
    model.traverse((node) => {
      if (node.isMesh) meshes++;
      if (node.isObject3D && !node.isMesh &&
          ['Muzzle', 'Eject', 'Sight', 'Grip', 'Stock', 'Barrel'].includes(node.name)) {
        node.updateWorldMatrix(true, false);
        const p = new THREE.Vector3();
        node.getWorldPosition(p);
        anchors[node.name] = [p.x, p.y, p.z].map((n) => Number(n.toFixed(6)));
      }
    });
    if (!anchors.Muzzle || !anchors.Eject || !anchors.Sight) {
      throw new Error(`${id} needs Muzzle, Eject, and Sight anchors`);
    }
    const optimization = mergeStaticMeshes(model);
    const data = await new GLTFExporter().parseAsync(model, { binary: true, onlyVisible: true });
    await fs.writeFile(path.join(outDir, `${id}.glb`), Buffer.from(data));
    await fs.writeFile(path.join(outDir, `${id}.json`), JSON.stringify({ version: 1, id, anchors, meshes: optimization.after, source_meshes: meshes }, null, 2) + '\n');
    console.log(`${id}: ${optimization.before} -> ${optimization.after} meshes, ${Buffer.byteLength(Buffer.from(data))} GLB bytes`);
  }
}
