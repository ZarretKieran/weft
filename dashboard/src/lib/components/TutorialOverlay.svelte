<script lang="ts">
	import { browser } from '$app/environment';
	import * as te from '$lib/telemetry-events';

	const TUTORIAL_DONE_KEY = 'weavemind_tutorial_done';
	const CALENDLY_URL = 'https://calendly.com/quentin101010/customer-interview';

	interface TutorialStep {
		title: string;
		description: string;
		targetSelector?: string;
		position?: 'top' | 'bottom' | 'left' | 'right' | 'center';
	}

	const steps: TutorialStep[] = [
		{
			title: 'Welcome to WeaveMind',
			description: "Let's take a quick tour so you know where everything is. You can skip at any time.",
			position: 'center',
		},
		{
			title: 'Your Projects',
			description: 'Projects are your automations. Each one is a pipeline of nodes that process data, call APIs, or run AI models.',
			targetSelector: 'a[href="/dashboard"]',
			position: 'bottom',
		},
		{
			title: 'Tangle, Your AI Builder',
			description: 'On any project page, Tangle appears in the sidebar. Describe what you want to build and it generates the project for you.',
			position: 'center',
		},
		{
			title: 'The Extension',
			description: 'Install the browser extension to enable human-in-the-loop tasks. Pause a project and wait for your input before continuing.',
			targetSelector: 'a[href="/extension"]',
			position: 'bottom',
		},
		{
			title: 'Book a Free Onboarding Call',
			description: "Get a personalized walkthrough of how automation can save you time and money. We'll also give you free credits at the end of the session.",
			position: 'center',
		},
	];

	let open = $state(false);
	let currentStep = $state(0);
	let highlightRect = $state<DOMRect | null>(null);

	export function start() {
		currentStep = 0;
		open = true;
		te.tutorial.started();
		updateHighlight();
	}

	function updateHighlight() {
		const step = steps[currentStep];
		if (step?.targetSelector && browser) {
			const el = document.querySelector(step.targetSelector);
			if (el) {
				highlightRect = el.getBoundingClientRect();
				return;
			}
		}
		highlightRect = null;
	}

	function next() {
		if (currentStep < steps.length - 1) {
			currentStep++;
			te.tutorial.stepReached(currentStep, steps.length);
			updateHighlight();
		} else {
			finish();
		}
	}

	function finish() {
		if (browser) localStorage.setItem(TUTORIAL_DONE_KEY, 'true');
		if (currentStep >= steps.length - 1) {
			te.tutorial.completed();
		} else {
			te.tutorial.skipped(currentStep, steps.length);
		}
		open = false;
		highlightRect = null;
	}

	const step = $derived(steps[currentStep]);
	const isLast = $derived(currentStep === steps.length - 1);
	const isCalendlyStep = $derived(currentStep === steps.length - 1);
</script>

{#if open}
	<!-- Backdrop with spotlight cutout -->
	<div
		class="fixed inset-0 z-[9000] pointer-events-none"
		aria-hidden="true"
	>
		{#if highlightRect}
			<!-- Dark overlay with hole -->
			<svg class="absolute inset-0 w-full h-full" xmlns="http://www.w3.org/2000/svg">
				<defs>
					<mask id="spotlight-mask">
						<rect width="100%" height="100%" fill="white" />
						<rect
							x={highlightRect.left - 6}
							y={highlightRect.top - 6}
							width={highlightRect.width + 12}
							height={highlightRect.height + 12}
							rx="8"
							fill="black"
						/>
					</mask>
				</defs>
				<rect width="100%" height="100%" fill="rgba(0,0,0,0.55)" mask="url(#spotlight-mask)" />
			</svg>
			<!-- Highlight ring -->
			<div
				class="absolute rounded-lg ring-2 ring-amber-400 ring-offset-0 transition-all duration-300"
				style="
					left: {highlightRect.left - 6}px;
					top: {highlightRect.top - 6}px;
					width: {highlightRect.width + 12}px;
					height: {highlightRect.height + 12}px;
				"
			></div>
		{:else}
			<div class="absolute inset-0 bg-black/50"></div>
		{/if}
	</div>

	<!-- Tooltip card -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div
		class="fixed z-[9001] pointer-events-auto"
		style={highlightRect
			? `left: ${Math.min(highlightRect.left, (typeof window !== 'undefined' ? window.innerWidth : 1200) - 340)}px; top: ${highlightRect.bottom + 16}px;`
			: 'left: 50%; top: 50%; transform: translate(-50%, -50%);'}
	>
		<div class="bg-white rounded-xl shadow-2xl border border-zinc-200 w-80 overflow-hidden">
			<!-- Progress bar -->
			<div class="h-1 bg-zinc-100">
				<div
					class="h-full bg-amber-400 transition-all duration-300"
					style="width: {((currentStep + 1) / steps.length) * 100}%"
				></div>
			</div>

			<div class="p-5">
				<!-- Step counter -->
				<div class="flex items-center justify-between mb-3">
					<span class="text-xs font-medium text-zinc-400 uppercase tracking-wider">
						Step {currentStep + 1} of {steps.length}
					</span>
					<button
						onclick={finish}
						class="text-xs text-zinc-400 hover:text-zinc-600 transition-colors"
					>
						Skip tour
					</button>
				</div>

				<h3 class="font-semibold text-zinc-900 text-base mb-1.5">{step.title}</h3>
				<p class="text-sm text-zinc-500 leading-relaxed">{step.description}</p>

				{#if isCalendlyStep}
					<a
						href={CALENDLY_URL}
						target="_blank"
						rel="noopener noreferrer"
						class="mt-4 flex items-center justify-center gap-2 w-full py-2.5 px-4 rounded-lg bg-amber-500 hover:bg-amber-600 text-white font-medium text-sm transition-colors"
					>
						<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
							<rect x="3" y="4" width="18" height="18" rx="2" ry="2"></rect>
							<line x1="16" y1="2" x2="16" y2="6"></line>
							<line x1="8" y1="2" x2="8" y2="6"></line>
							<line x1="3" y1="10" x2="21" y2="10"></line>
						</svg>
						Book a free onboarding call
					</a>
					<p class="text-xs text-zinc-400 text-center mt-2">Free credits included at the end of the session</p>
				{/if}

				<div class="flex items-center justify-between mt-4">
					{#if currentStep > 0}
						<button
							onclick={() => { currentStep--; updateHighlight(); }}
							class="text-sm text-zinc-400 hover:text-zinc-600 transition-colors"
						>
							← Back
						</button>
					{:else}
						<div></div>
					{/if}

					<button
						onclick={next}
						class="px-4 py-1.5 rounded-lg bg-zinc-900 hover:bg-zinc-700 text-white text-sm font-medium transition-colors"
					>
						{isLast ? 'Done' : 'Next →'}
					</button>
				</div>
			</div>
		</div>
	</div>
{/if}
