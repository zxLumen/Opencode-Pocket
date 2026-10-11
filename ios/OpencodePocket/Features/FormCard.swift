import SwiftUI

struct FormCard: View {
    @Environment(PocketStore.self) private var store
    let form: FormInfo

    @State private var strings: [String: String] = [:]
    @State private var numbers: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var multi: [String: Set<String>] = [:]
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(form.title, systemImage: "list.bullet.rectangle")
                .font(.subheadline.bold())

            ForEach(form.fields, id: \.key) { field in
                fieldView(field)
            }

            Button("提交") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        }
        .padding(.vertical, 4)
        .onAppear(perform: setup)
    }

    @ViewBuilder
    private func fieldView(_ field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.type != "boolean" {
                Text(field.displayTitle + (field.required == true ? " *" : ""))
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            if let d = field.description, !d.isEmpty {
                Text(d).font(.caption2).foregroundStyle(.secondary)
            }

            switch field.type {
            case "multiselect":
                ForEach(field.options ?? [], id: \.value) { opt in
                    Button { toggleMulti(field.key, opt.value) } label: {
                        HStack {
                            Image(systemName: (multi[field.key]?.contains(opt.value) ?? false)
                                  ? "checkmark.square.fill" : "square")
                            VStack(alignment: .leading) {
                                Text(opt.label)
                                if let d = opt.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

            case "boolean":
                Toggle(field.displayTitle, isOn: bindingBool(field.key))

            case "number", "integer":
                TextField("数字", text: bindingNumber(field.key))
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)

            case "external":
                if let u = field.url, let url = URL(string: u) {
                    Link("打开链接", destination: url).font(.caption)
                }

            default:
                TextField("输入…", text: bindingString(field.key), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func setup() {
        for f in form.fields where f.type == "boolean" && bools[f.key] == nil {
            bools[f.key] = false
        }
    }

    private func bindingString(_ k: String) -> Binding<String> {
        Binding(get: { strings[k] ?? "" }, set: { strings[k] = $0 })
    }
    private func bindingNumber(_ k: String) -> Binding<String> {
        Binding(get: { numbers[k] ?? "" }, set: { numbers[k] = $0 })
    }
    private func bindingBool(_ k: String) -> Binding<Bool> {
        Binding(get: { bools[k] ?? false }, set: { bools[k] = $0 })
    }
    private func toggleMulti(_ k: String, _ v: String) {
        var set = multi[k] ?? []
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
        multi[k] = set
    }

    private func submit() {
        busy = true
        var answer: [String: Any] = [:]
        for f in form.fields {
            switch f.type {
            case "boolean":
                answer[f.key] = bools[f.key] ?? false
            case "number", "integer":
                if let s = numbers[f.key], !s.isEmpty {
                    answer[f.key] = (f.type == "integer") ? (Int(s) ?? 0) : (Double(s) ?? 0)
                }
            case "multiselect":
                if let set = multi[f.key] { answer[f.key] = Array(set) }
            case "external":
                break
            default:
                if let s = strings[f.key], !s.isEmpty { answer[f.key] = s }
            }
        }
        Task {
            await store.replyForm(form, answer: answer)
            busy = false
        }
    }
}
