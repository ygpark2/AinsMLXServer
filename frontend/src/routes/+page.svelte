<script lang="ts">
	import { onMount } from 'svelte';
	import { Send, User, Bot, Loader2 } from 'lucide-svelte';

	interface Message {
		role: 'user' | 'assistant';
		content: string;
	}

	let messages = $state<Message[]>([
		{ role: 'assistant', content: 'Welcome! I am AinsMLXServer. How can I help you today?' }
	]);
	let userInput = $state('');
	let isLoading = $state(false);
	let chatContainer = $state<HTMLElement | null>(null);

	$effect(() => {
		if (messages.length && chatContainer) {
			chatContainer.scrollTop = chatContainer.scrollHeight;
		}
	});

	async function sendMessage() {
		if (!userInput.trim() || isLoading) return;

		const text = userInput.trim();
		messages = [...messages, { role: 'user', content: text }];
		userInput = '';
		isLoading = true;

		try {
			const response = await fetch('http://localhost:8080/v1/chat/completions', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					messages: [{ role: 'user', content: text }]
				})
			});

			if (!response.ok) throw new Error('Server response error');

			const data = await response.json();
			messages = [...messages, { role: 'assistant', content: data.choices[0].message.content }];
		} catch (error: any) {
			messages = [
				...messages,
				{ role: 'assistant', content: `An error occurred: ${error.message}` }
			];
		} finally {
			isLoading = false;
		}
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendMessage();
		}
	}
</script>

<div class="flex h-screen flex-col bg-gray-50 text-gray-900 font-sans">
	<header class="flex items-center justify-between border-b bg-white px-6 py-4 shadow-sm">
		<div class="flex items-center gap-2">
			<div class="h-8 w-8 rounded-lg bg-blue-600 flex items-center justify-center text-white">
				<Bot size={20} />
			</div>
			<h1 class="text-xl font-bold tracking-tight">AinsMLXServer</h1>
		</div>
		<div class="flex items-center gap-2">
			<span class="flex h-2 w-2 rounded-full bg-green-500"></span>
			<span class="text-sm font-medium text-gray-500">Connected</span>
		</div>
	</header>

	<main
		bind:this={chatContainer}
		class="flex-1 overflow-y-auto p-4 md:p-8 space-y-6 max-w-4xl mx-auto w-full"
	>
		{#each messages as msg}
			<div class="flex {msg.role === 'user' ? 'justify-end' : 'justify-start'} animate-in fade-in slide-in-from-bottom-2 duration-300">
				<div class="flex max-w-[85%] gap-3 {msg.role === 'user' ? 'flex-row-reverse' : ''}">
					<div
						class="flex h-8 w-8 shrink-0 select-none items-center justify-center rounded-full border shadow-sm
                        {msg.role === 'user' ? 'bg-blue-600 text-white border-transparent' : 'bg-white text-gray-600'}"
					>
						{#if msg.role === 'user'}
							<User size={16} />
						{:else}
							<Bot size={16} />
						{/if}
					</div>
					<div
						class="relative flex flex-col gap-2 rounded-2xl px-4 py-3 text-sm shadow-sm
                        {msg.role === 'user'
							? 'bg-blue-600 text-white rounded-tr-none'
							: 'bg-white border text-gray-800 rounded-tl-none'}"
					>
						{#if msg.content.includes('```')}
							<!-- Simple Markdown code block handling -->
							{#each msg.content.split('```') as part, i}
								{#if i % 2 === 1}
									<pre class="my-2 overflow-x-auto rounded-lg bg-gray-900 p-3 text-xs text-gray-100"><code>{part.replace(/^\w+\n/, '')}</code></pre>
								{:else if part.trim()}
									<p class="whitespace-pre-wrap">{part}</p>
								{/if}
							{/each}
						{:else}
							<p class="whitespace-pre-wrap">{msg.content}</p>
						{/if}
					</div>
				</div>
			</div>
		{/each}

		{#if isLoading}
			<div class="flex justify-start animate-pulse">
				<div class="flex max-w-[85%] gap-3">
					<div class="flex h-8 w-8 items-center justify-center rounded-full border bg-white text-gray-400">
						<Bot size={16} />
					</div>
					<div class="rounded-2xl bg-white border px-4 py-3 text-sm text-gray-400 rounded-tl-none">
						<Loader2 class="animate-spin" size={16} />
					</div>
				</div>
			</div>
		{/if}
	</main>

	<footer class="border-t bg-white p-4 shadow-[0_-1px_3px_rgba(0,0,0,0.05)]">
		<div class="mx-auto flex max-w-4xl items-end gap-3">
			<div class="relative flex-1">
				<textarea
					bind:value={userInput}
					onkeydown={handleKeydown}
					placeholder="Type your message here..."
					class="w-full resize-none rounded-xl border border-gray-200 bg-gray-50 px-4 py-3 pr-12 text-sm focus:border-blue-500 focus:bg-white focus:outline-none focus:ring-2 focus:ring-blue-500/20 transition-all min-h-[50px] max-h-[200px]"
					rows="1"
				></textarea>
				<button
					onclick={sendMessage}
					disabled={!userInput.trim() || isLoading}
					class="absolute right-2 bottom-2 p-2 rounded-lg bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
				>
					{#if isLoading}
						<Loader2 size={18} class="animate-spin" />
					{:else}
						<Send size={18} />
					{/if}
				</button>
			</div>
		</div>
		<p class="mt-2 text-center text-[10px] text-gray-400">Powered by AinsMLXServer</p>
	</footer>
</div>

<style>
	:global(body) {
		margin: 0;
		padding: 0;
	}
    
    .animate-in {
        animation: animate-in 0.3s ease-out;
    }
    
    @keyframes animate-in {
        from { opacity: 0; transform: translateY(10px); }
        to { opacity: 1; transform: translateY(0); }
    }
</style>
