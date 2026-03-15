interface StatusDotProps {
  color: string;
  count: number;
}

export default function StatusDot({ color, count }: StatusDotProps) {
  if (count <= 0) return <box />;

  return (
    <box spacing={2} cssClasses={["status-dot"]}>
      <label label="●" cssClasses={["dot-icon"]} css={`color: ${color};`} />
      <label label={String(count)} cssClasses={["dot-count"]} css={`color: ${color};`} />
    </box>
  );
}
