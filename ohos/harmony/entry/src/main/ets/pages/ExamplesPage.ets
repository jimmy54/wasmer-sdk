import { router } from "@kit.ArkUI";

interface ExampleEntry {
  title: string;
  upstream: string;
  page: string;
}

const EXAMPLES: ExampleEntry[] = [
  {
    title: "Python",
    upstream: "js/examples/python.mjs",
    page: "pages/PythonPage",
  },
  {
    title: "Multiple runtimes",
    upstream: "js/examples/multiple_runtimes.mjs",
    page: "pages/MultipleRuntimesPage",
  },
  {
    title: "Edge.js HTTP server",
    upstream: "js/examples/edgejs_http.mjs",
    page: "pages/EdgeHttpPage",
  },
  {
    title: "Shell tools",
    upstream: "README shell-tools example",
    page: "pages/BashPage",
  },
  {
    title: "Interactive terminal",
    upstream: "README terminal example",
    page: "pages/TerminalPage",
  },
];

@Entry
@Component
struct ExamplesPage {
  build() {
    Column({ space: 12 }) {
      Text("Official examples")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor("#E6E9F0")
      Text("Ported from wasmerio/wasmer-sdk")
        .fontSize(13)
        .fontColor("#8A93A6")
      List({ space: 10 }) {
        ForEach(EXAMPLES, (example: ExampleEntry) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(example.title)
                .fontSize(17)
                .fontColor("#C9D1E0")
              Text(example.upstream)
                .fontSize(12)
                .fontColor("#8A93A6")
            }
            .alignItems(HorizontalAlign.Start)
            .width("100%")
            .padding(12)
            .backgroundColor("#151922")
            .borderRadius(10)
            .onClick(() => {
              router.pushUrl({ url: example.page });
            })
          }
        }, (example: ExampleEntry) => example.page)
      }
      .layoutWeight(1)
      .width("100%")
    }
    .padding(20)
    .width("100%")
    .height("100%")
    .alignItems(HorizontalAlign.Start)
    .backgroundColor("#0B0D12")
  }
}
