import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { mergeStaticMeshes } from './optimize.mjs';

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
const outDir = path.resolve(here, '../../assets/models/characters');
const ids = process.argv.slice(2);
if (!ids.length) throw new Error('Usage: node export_characters.mjs grunt [brute ...]');
await fs.mkdir(outDir, { recursive: true });
for (const id of ids) {
  if (!/^[a-z][a-z0-9_]*$/.test(id)) throw new Error('Invalid character id');
  const module = await import(`../character_models/${id}.mjs`);
  const factory = Object.values(module).find((v) => typeof v === 'function');
  const model = factory(THREE);
  if (!(model instanceof THREE.Group)) throw new Error(`${id} is not a Group`);
  model.name = `Character_${id}`;
  const pivots = {};
  let meshes = 0;
  model.traverse((node) => {
    if (node.isMesh) meshes++;
    if (['BodyRoot', 'HipL', 'HipR', 'ShoulderL', 'ShoulderR', 'Head'].includes(node.name)) {
      node.updateWorldMatrix(true, false);
      const p = new THREE.Vector3();
      node.getWorldPosition(p);
      pivots[node.name] = [p.x, p.y, p.z].map((n) => Number(n.toFixed(6)));
    }
  });
  if (Object.keys(pivots).length !== 6) throw new Error(`${id} missing animation pivots`);
  const optimization = mergeStaticMeshes(model);
  const data = await new GLTFExporter().parseAsync(model, { binary: true });
  await fs.writeFile(path.join(outDir, `${id}.glb`), Buffer.from(data));
  await fs.writeFile(path.join(outDir, `${id}.json`), JSON.stringify({ version: 1, id, pivots, meshes: optimization.after, source_meshes: meshes }, null, 2) + '\n');
  console.log(`${id}: ${optimization.before} -> ${optimization.after} meshes, ${Buffer.byteLength(Buffer.from(data))} bytes`);
}
