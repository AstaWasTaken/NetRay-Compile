import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
    title: "NetRay Compile",
    description: "Documentation for the NetRay IDL compiler Studio plugin",
    base: "/NetRay-Compile/", // Important for GitHub Pages deployment
    themeConfig: {
        siteTitle: false,
        logo: '/Vector.png',
        // https://vitepress.dev/reference/default-theme-config
        nav: [
            { text: 'Home', link: '/' },
            { text: 'Getting Started', link: '/getting-started' },
            { text: 'Reference', link: '/schema-reference' },
            { text: 'Changelog', link: '/changelog' }
        ],

        sidebar: [
            {
                text: 'Introduction',
                items: [
                    { text: 'Getting Started', link: '/getting-started' },
                    { text: 'Changelog', link: '/changelog' }
                ]
            },
            {
                text: 'Core Concepts',
                items: [
                    { text: 'Runtime Model', link: '/runtime-model' },
                    { text: 'Type System', link: '/type-system' }
                ]
            },
            {
                text: 'Workflow',
                items: [
                    { text: 'Studio Plugin', link: '/studio-plugin-workflow' },
                    { text: 'Using Generated API', link: '/generated-api' }
                ]
            },
            {
                text: 'IDL Reference',
                items: [
                    { text: 'Syntax Guide', link: '/schema-reference' },
                    { text: 'Examples', link: '/schema-examples' },
                    { text: 'Options', link: '/options' }
                ]
            },
            {
                text: 'Support',
                items: [
                    { text: 'Troubleshooting', link: '/errors-and-troubleshooting' },
                    { text: 'FAQ', link: '/faq' }
                ]
            }
        ],

        socialLinks: [
            { icon: 'github', link: 'https://github.com/AstaWasTaken/NetRay-Compiler' }
        ],

        footer: {
            message: 'NetRay Compiler docs. Current supported frontend: Roblox Studio plugin.',
            copyright: 'Copyright © 2024-present'
        }
    }
})
