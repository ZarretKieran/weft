import type { NodeTemplate } from '$lib/types';
import { CodeXml } from '@lucide/svelte';

export const CodeNode: NodeTemplate = {
	type: 'ExecPython',
	label: 'Code',
	description: 'Execute Python code. Input ports are injected as variables, output is a dict with one key per output port.',
	isBase: true,
	icon: CodeXml,
	color: '#5a8a6e',
	category: 'Utility',
	tags: ['python', 'script', 'transform', 'logic', 'compute'],
	fields: [
		{ key: 'code', label: 'Python Code', type: 'code', placeholder: '# Input ports become variables directly\n# Output ports are extracted from your outputed dict\n# e.g., if you have ports "data" and "threshold":\nif data["value"] > threshold:\n    return {"high": data, "low": None}\nelse:\n    return {"high": None, "low": data}' },
		{ key: 'dependencies', label: 'requirements.txt', type: 'code', placeholder: '# Pre-installed (available instantly):\n# numpy, pandas, requests, pillow, pyyaml\n# beautifulsoup4, lxml, scipy, scikit-learn\n# matplotlib, httpx, aiohttp\n#\n# Add extra packages below (one per line):\n# some-package==1.0.0\n# another-package>=2.0' },
	],
	defaultInputs: [],
	defaultOutputs: [],
	features: {
		canAddInputPorts: true,
		canAddOutputPorts: true,
	},
};
